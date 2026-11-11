import Combine
import Foundation
import os

// GestaltAccess is an ObjC class whose state is guarded by internal serial queues.
extension GestaltAccess: @unchecked Sendable {}

@MainActor
final class GestaltViewModel: ObservableObject {
    @Published var plist: GestaltPlist?
    @Published var isDirty = false
    @Published var isBusy = false
    @Published var notice: GestaltNotice?
    @Published private(set) var hasAttemptedLoad = false
    @Published private(set) var backups: [GestaltBackup] = []
    @Published private(set) var patches: [GestaltPatch] = []
    @Published var selectedTweaks: Set<GestaltTweakID> = []
    @Published var dynamicIslandSubtype: Int?
    @Published var changesModelName = false
    @Published var modelName = ""
    @Published var stagesAIRegion = false
    @Published private(set) var isRespringing = false

    /// The most recent automatic backup, for "Undo Last Write" support.
    /// Set during `save()` so the user can one-tap revert.
    @Published private(set) var lastAutoBackup: GestaltBackup?

    /// Monotonically incremented each time a respring timeout is scheduled.
    /// Used to cancel a stale timeout if a new save happens before the old
    /// timeout fires.
    private var respringTimeoutToken = 0

    private let access = GestaltAccess.shared()

    // Serial queue for read-backup-write-verify operations on the plist.
    private let saveQueue = DispatchQueue(label: "com.wesk.gestalt.save")

    /// Cached set of tweaks currently applied in the plist. Recomputed in
    /// `syncTogglesFromPlist()` and `load()`. Avoids re-iterating all
    /// tweak definitions on every SwiftUI body re-render.
    private var _appliedTweaksCache: Set<GestaltTweakID> = []
    /// Cached plist subtype for Dynamic Island (or nil).
    private var _appliedSubtypeCache: Int?
    /// Cached plist model name (or nil).
    private var _appliedModelNameCache: String?

    var aiRegionProfile: AIRegionProfile? {
        plist.flatMap(AIRegionProfile.init(plist:))
    }

    var requiresForcedAIEnable: Bool {
        plist != nil && aiRegionProfile == nil
    }

    var isAIRegionConfigured: Bool {
        guard let profile = aiRegionProfile,
              let cacheExtra = plist?.cacheExtra else { return false }
        return cacheExtra["h63QSdBCiT/z0WU6rdQv6Q"] as? String == "LL"
            && cacheExtra["yK+xavymRGZ3xWc1tb8XDg"] as? String == "LL/A"
            && cacheExtra["97JDvERpVwO+GHtthIh7hA"] as? String == profile.regulatoryModel
    }

    /// True when the UI toggle state differs from what's currently in the
    /// plist. This covers both newly-selected tweaks AND tweaks that were
    /// previously applied but are now toggled OFF (revert). Without this,
    /// turning off the last applied tweak would make the apply bar vanish
    /// and the user could never commit the revert.
    var hasStagedTweaks: Bool {
        if selectedTweaks != _appliedTweaksCache { return true }
        if dynamicIslandSubtype != _appliedSubtypeCache { return true }
        let uiWantsName = changesModelName && !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let plistHasName = _appliedModelNameCache != nil && !(_appliedModelNameCache?.isEmpty ?? true)
        if uiWantsName != plistHasName { return true }
        if uiWantsName && _appliedModelNameCache != modelName { return true }
        if stagesAIRegion != isAIRegionConfigured { return true }
        return false
    }

    /// Count of pending changes (new tweaks + reverts + Dynamic Island +
    /// model name + AI Region). Each category counts as 1.
    var stagedChangeCount: Int {
        let newTweaks = selectedTweaks.subtracting(_appliedTweaksCache).count
        let revertedTweaks = _appliedTweaksCache.subtracting(selectedTweaks).count
        var count = newTweaks + revertedTweaks
        if dynamicIslandSubtype != _appliedSubtypeCache { count += 1 }
        let uiWantsName = changesModelName && !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let plistHasName = _appliedModelNameCache != nil && !(_appliedModelNameCache?.isEmpty ?? true)
        if uiWantsName != plistHasName || (uiWantsName && _appliedModelNameCache != modelName) {
            count += 1
        }
        if stagesAIRegion != isAIRegionConfigured { count += 1 }
        return count
    }

    struct PendingChangeEntry: Identifiable {
        let id = UUID()
        let category: String
        let field: String
        let oldValue: String
        let newValue: String
    }

    var pendingChangeEntries: [PendingChangeEntry] {
        var entries: [PendingChangeEntry] = []
        let allTweaks = GestaltTweakCatalog.definitions.reduce(into: [GestaltTweakID: String]()) { $0[$1.id] = $1.title }

        let newTweaks = selectedTweaks.subtracting(_appliedTweaksCache)
        let revertedTweaks = _appliedTweaksCache.subtracting(selectedTweaks)

        for id in newTweaks.sorted(by: { ($0.rawValue) < ($1.rawValue) }) {
            let title = allTweaks[id] ?? id.rawValue
            entries.append(PendingChangeEntry(
                category: String(localized: "Tweak"),
                field: title,
                oldValue: String(localized: "Off"),
                newValue: String(localized: "On")
            ))
        }
        for id in revertedTweaks.sorted(by: { ($0.rawValue) < ($1.rawValue) }) {
            let title = allTweaks[id] ?? id.rawValue
            entries.append(PendingChangeEntry(
                category: String(localized: "Tweak"),
                field: title,
                oldValue: String(localized: "On"),
                newValue: String(localized: "Off")
            ))
        }

        if dynamicIslandSubtype != _appliedSubtypeCache {
            entries.append(PendingChangeEntry(
                category: String(localized: "Dynamic Island"),
                field: String(localized: "Subtype"),
                oldValue: _appliedSubtypeCache.map { String(describing: $0) } ?? String(localized: "Default"),
                newValue: String(describing: dynamicIslandSubtype)
            ))
        }

        let uiWantsName = changesModelName && !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let plistHasName = _appliedModelNameCache != nil && !(_appliedModelNameCache?.isEmpty ?? true)
        if uiWantsName != plistHasName || (uiWantsName && _appliedModelNameCache != modelName) {
            let oldVal = _appliedModelNameCache ?? String(localized: "Default")
            let newVal = uiWantsName ? modelName.trimmingCharacters(in: .whitespacesAndNewlines) : String(localized: "Default")
            entries.append(PendingChangeEntry(
                category: String(localized: "Device Name"),
                field: String(localized: "Model Name"),
                oldValue: oldVal,
                newValue: newVal
            ))
        }

        if stagesAIRegion != isAIRegionConfigured {
            entries.append(PendingChangeEntry(
                category: String(localized: "AI Region"),
                field: String(localized: "Enabled"),
                oldValue: isAIRegionConfigured ? String(localized: "On") : String(localized: "Off"),
                newValue: stagesAIRegion ? String(localized: "On") : String(localized: "Off")
            ))
        }

        return entries
    }

    func load() {
        guard !isBusy else { return }
        hasAttemptedLoad = true
        isBusy = true
        isRespringing = false
        notice = nil

        // Run connect + plist read off the main actor.
        let access = self.access
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try access.connect()
                guard let dictionary = try access.readGestalt() as? [String: Any] else {
                    throw GestaltKitToolError.invalidPlist
                }
                let loaded = GestaltPlist(dict: dictionary)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.plist = loaded
                    self.isDirty = false
                    self.syncTogglesFromPlist()
                    self.refreshBackups()
                    self.refreshPatches()
                    self.isBusy = false
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.plist = nil
                    self.report(error)
                    self.isBusy = false
                }
            }
        }
    }

    func setTweak(_ id: GestaltTweakID, enabled: Bool) {
        if enabled {
            selectedTweaks.insert(id)
            if id == .enableLiquidGlassLowPerformance {
                selectedTweaks.remove(.disableLiquidGlassLowPerformance)
            } else if id == .disableLiquidGlassLowPerformance {
                selectedTweaks.remove(.enableLiquidGlassLowPerformance)
            }
            // iPadOS Mode conflicts with iPad-app compatibility mode:
            // running iPad apps in compatibility mode overrides the
            // "device is an iPad" identity decision, breaking multi-window
            // and other iPadOS features. Make them mutually exclusive.
            if id == .iPadOS {
                selectedTweaks.remove(.iPadApps)
                selectedTweaks.remove(.stageManager)
            } else if id == .iPadApps || id == .stageManager {
                selectedTweaks.remove(.iPadOS)
            }
        } else {
            selectedTweaks.remove(id)
        }
    }

    func setAIRegion(enabled: Bool) {
        stagesAIRegion = enabled
        if enabled, requiresForcedAIEnable {
            notice = GestaltNotice(
                kind: .riskWarning,
                message: String(localized: "This device does not officially support Siri AI. Force enabling spoofs the product, hardware, and CPU model. It may temporarily break Face ID, cause system instability or boot loops, and could require restoring the device. A backup will be created before writing.")
            )
        }
    }

    func applySelectedTweaks() {
        guard !isBusy, hasStagedTweaks, var pending = plist else { return }
        do {
            // --- Determine which tweaks are currently in the plist ---
            let previouslyApplied = currentlyAppliedTweaks(in: pending)

            // --- Revert tweaks that are no longer selected ---
            let tweaksToRevert = previouslyApplied.subtracting(selectedTweaks)
            for id in tweaksToRevert {
                guard let definition = GestaltTweakCatalog.definition(for: id) else { continue }
                pending.revert(definition: definition)
            }

            // --- Enforce iPadOS-mode exclusivity ---
            // If iPadOS mode is being applied, "Allow iPad Apps" must be
            // disabled: the compatibility-mode array [1,2] makes the system
            // treat iPad identity as a compatibility fallback, which breaks
            // multi-window. Defensive: applies even if the stale plist
            // already contains both.
            if selectedTweaks.contains(.iPadOS),
               let iPadAppsDef = GestaltTweakCatalog.definition(for: .iPadApps) {
                pending.revert(definition: iPadAppsDef)
            }

            // --- Apply newly selected tweaks ---
            for id in selectedTweaks {
                guard let definition = GestaltTweakCatalog.definition(for: id) else { continue }
                try pending.apply(definition: definition)
            }

            // --- Dynamic Island subtype ---
            // Only touch the plist if the UI state differs from what's
            // already stored. This avoids writing unnecessary values.
            let plistSubtype = currentDynamicIslandSubtype(in: pending)
            if dynamicIslandSubtype != plistSubtype {
                if let dynamicIslandSubtype {
                    try pending.setDynamicIslandSubtype(dynamicIslandSubtype)
                } else {
                    pending.revertDynamicIsland()
                }
            }

            // --- Model name ---
            
            let plistModelName = currentModelName(in: pending)
            let uiModelName = changesModelName
                ? modelName.trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            if changesModelName {
                switch ModelNameValidator.validate(uiModelName) {
                case .ok:
                    break
                case .empty:
                    throw GestaltKitToolError.emptyModelName
                case .tooLong:
                    throw GestaltKitToolError.modelNameTooLong
                case .invalidCharacters:
                    throw GestaltKitToolError.modelNameInvalidChars
                }
            }
            let plistHasName = plistModelName != nil && !(plistModelName?.isEmpty ?? true)
            let uiWantsName = changesModelName && !uiModelName.isEmpty
            if uiWantsName != plistHasName || (uiWantsName && uiModelName != (plistModelName ?? "")) {
                if uiWantsName {
                    try pending.setModelName(uiModelName)
                } else {
                    pending.revertModelName()
                }
            }

            // --- AI Region ---
            var expectedConfiguration: AIRegionConfiguration?
            if stagesAIRegion != isAIRegionConfigured {
                if stagesAIRegion {
                    let configuration = AIRegionConfiguration.resolve(for: pending)
                    let profile = configuration.profile
                    if let productType = configuration.spoofedProductType,
                       let hardwareModel = configuration.spoofedHardwareModel,
                       let cpuModel = configuration.spoofedCPUModel {
                        pending.setCacheExtra(1, forKey: "A62OafQ85EJAiiqKn4agtg")
                        pending.setCacheExtra(productType, forKey: "h9jDsbgj7xIVeIQ8S3/X3Q")
                        pending.setCacheExtra(hardwareModel, forKey: "oYicEKzVTz4/CxxE05pEgQ")
                        pending.setCacheExtra(cpuModel, forKey: "5pYKlGnYYBzGvAlIU8RjEQ")
                    }
                    pending.setCacheExtra("LL", forKey: "h63QSdBCiT/z0WU6rdQv6Q")
                    pending.setCacheExtra("LL/A", forKey: "yK+xavymRGZ3xWc1tb8XDg")
                    pending.setCacheExtra(profile.regulatoryModel, forKey: "97JDvERpVwO+GHtthIh7hA")
                    expectedConfiguration = configuration
                } else {
                    pending.revertAIRegion()
                }
            }
            save(pending, expectedAIRegion: expectedConfiguration, expectedTweaks: selectedTweaks)
        } catch {
            report(error)
        }
    }

    func applyChanges() {
        guard !isBusy, let plist else { return }
        save(plist, expectedAIRegion: nil)
    }

    /// Reverts all known tweaks to their disabled / factory state and
    /// writes the result. A backup is created automatically by `save()`.
    func restoreFactorySettings() {
        guard !isBusy, var pending = plist else { return }
        pending.revertAllTweaks()
        // Clear UI state so syncTogglesFromPlist after save reflects the
        // reverted plist, not stale toggle positions.
        selectedTweaks = []
        dynamicIslandSubtype = nil
        changesModelName = false
        modelName = ""
        stagesAIRegion = false
        save(pending, expectedAIRegion: nil)
    }

    /// One-tap undo — restores the most recent automatic backup created
    /// during the last `save()` call. Returns silently if no write has
    /// happened yet this session.
    func undoLastWrite() {
        guard let backup = lastAutoBackup else { return }
        restore(backup)
    }

    /// True when undo is available (a write happened this session and no
    /// operation is currently in progress).
    var canUndoLastWrite: Bool {
        lastAutoBackup != nil && !isBusy
    }

    /// Sets or clears a user-editable label on a backup. The label is
    /// persisted in UserDefaults via BackupLabelStore and surfaces in the
    /// backup list UI.
    func setBackupLabel(_ label: String?, for backup: GestaltBackup) {
        BackupLabelStore.setLabel(label, for: backup.name)
        refreshBackups()
    }

    func createBackup() {
        guard !isBusy else { return }
        isBusy = true

        // XPC + file I/O off the main actor.
        let access = self.access
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try access.connect()
                let data = try access.readGestaltData()
                let backup = try GestaltBackupStore.create(from: data, isManual: true)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.refreshBackups()
                    self.notice = GestaltNotice(
                        kind: .backupCreated,
                        message: String(
                            format: String(localized: "Saved %@.plist. You can export it from the Backups tab."),
                            backup.name
                        )
                    )
                    self.isBusy = false
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.report(error)
                    self.isBusy = false
                }
            }
        }
    }

    func importBackup(from url: URL) {
        guard !isBusy else { return }
        isBusy = true

        // The previous synchronous version blocked the main thread with
        // Data(contentsOf:) + PropertyListSerialization for large backup
        // files (MobileGestalt plist can be several MB).
        let accessed = url.startAccessingSecurityScopedResource()

        Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                var format = PropertyListSerialization.PropertyListFormat.binary
                guard let dictionary = try PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: &format
                ) as? [String: Any],
                      dictionary["CacheExtra"] is [String: Any] else {
                    throw GestaltKitToolError.invalidBackup
                }
                let backup = try GestaltBackupStore.create(from: data, isManual: true)
                let fileName = url.lastPathComponent
                let backupName = backup.name
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.refreshBackups()
                    self.notice = GestaltNotice(
                        kind: .backupCreated,
                        message: String(
                            format: String(localized: "Imported %@ and saved it as %@.plist."),
                            fileName,
                            backupName
                        )
                    )
                    self.isBusy = false
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.report(error)
                    self.isBusy = false
                }
            }
        }
    }

    func restore(_ backup: GestaltBackup) {
        guard !isBusy else { return }
        isBusy = true

        // GestaltBackupStore.data(for:) reads from disk and
        // PropertyListSerialization parses synchronously — both can
        // block the main thread for large backups.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let data = try GestaltBackupStore.data(for: backup)
                var format = PropertyListSerialization.PropertyListFormat.binary
                guard let dictionary = try PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: &format
                ) as? [String: Any],
                      dictionary["CacheExtra"] is [String: Any] else {
                    throw GestaltKitToolError.invalidBackup
                }
                let restoredPlist = GestaltPlist(dict: dictionary)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // save() manages isBusy, backup, verification, respring.
                    self.save(restoredPlist, expectedAIRegion: nil)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.report(error)
                    self.isBusy = false
                }
            }
        }
    }

    func delete(_ backup: GestaltBackup) {
        do {
            try GestaltBackupStore.delete(backup)
            refreshBackups()
        } catch {
            report(error)
        }
    }

    /// Deletes multiple backups in one operation (batch delete).
    func deleteBackups(_ backupsToDelete: [GestaltBackup]) {
        var errors: [Error] = []
        for backup in backupsToDelete {
            do {
                try GestaltBackupStore.delete(backup)
            } catch {
                errors.append(error)
            }
        }
        refreshBackups()
        if let firstError = errors.first {
            report(firstError)
        }
    }

    func refreshBackups() {
        do {
            backups = try GestaltBackupStore.list()
        } catch {
            report(error)
        }
    }

    func refreshPatches() {
        do {
            patches = try GestaltPatchStore.list()
        } catch {
            GKTLLog.patch.error("refreshPatches failed: \(error.localizedDescription)")
            notice = GestaltNotice(
                kind: .error,
                message: String(localized: "Failed to load patches. A corrupt patch file may have been removed or moved.")
            )
            patches = []
        }
    }

    // MARK: - Patches

    /// Exports the given CacheExtra keys from the current plist as a
    /// shareable `.weskpatch`. Only the selected keys are written into
    /// the patch, so it stays device-independent.
    func exportPatch(name: String, author: String?, notes: String?, keys: [String]) {
        guard !isBusy, let plist else { return }
        isBusy = true

        // off the main actor. The encoding loop and GestaltPatchStore.create()
        // involve disk I/O that can briefly block the UI for large patches.
        let cacheExtra = plist.cacheExtra

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var fieldValues: [String: GestaltPatchContent.FieldValue] = [:]
            var skippedKeys: [String] = []
            for key in keys {
                guard let value = cacheExtra[key] else { continue }
                let kind = PlistValueKind.kind(of: value)
                let encoded = PlistValueInfo.encode(value, as: kind)
                // Skip when encode returns "" (plist contains NSDate/NSData etc.
                // that can't be JSON-serialized). parse("", as: .data) would
                // return empty Data, which differs semantically from the original.
                guard !encoded.isEmpty else {
                    skippedKeys.append(key)
                    continue
                }
                fieldValues[key] = .init(kind: kind.rawValue, encodedValue: encoded)
            }

            guard !fieldValues.isEmpty else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.notice = GestaltNotice(
                        kind: .error,
                        message: String(localized: "No matching CacheExtra keys to export.")
                    )
                    self.isBusy = false
                }
                return
            }

            let content = GestaltPatchContent(
                formatVersion: GestaltPatchContent.formatVersion,
                name: name,
                author: author,
                notes: notes,
                createdAt: Date(),
                cacheExtra: fieldValues
            )
            do {
                _ = try GestaltPatchStore.create(content)
                let fieldCount = fieldValues.count
                let skippedCount = skippedKeys.count
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.refreshPatches()
                    let base = String(
                        format: String(localized: "Exported patch %@ (%d fields)."),
                        name, fieldCount
                    )
                    let tail = skippedCount == 0
                        ? ""
                        : " " + String(
                            format: String(localized: "(%d unencodable fields skipped.)"),
                            skippedCount)
                    self.notice = GestaltNotice(kind: .backupCreated, message: base + tail)
                    self.isBusy = false
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.report(error)
                    self.isBusy = false
                }
            }
        }
    }

    /// Imports a `.weskpatch` from a user-selected URL, applies it on top
    /// of the current plist, and saves. A copy is also stored in the
    /// patch library for re-use. `save()` manages isBusy, backup,
    /// verification, and respring.
    func importPatch(from url: URL) {
        guard !isBusy, var plist else { return }
        isBusy = true

        // Data(contentsOf:) is the expensive part (disk I/O). The JSON
        // decode is fast and kept on the main actor to avoid the Swift 6
        // warning about Decodable conformance in a nonisolated context.
        let accessed = url.startAccessingSecurityScopedResource()

        Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            guard let self else { return }
            do {
                let data = try Data(contentsOf: url)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    do {
                        let content = try JSONDecoder().decode(GestaltPatchContent.self, from: data)
                        try self.applyPatchContent(content, to: &plist)
                        // succeeds — if save fails, a pre-stored patch would let the
                        // user re-trigger the same failure.
                        let pendingPatchContent = content
                        self.save(plist, expectedAIRegion: nil) { [weak self] success in
                            guard let self else { return }
                            if success {
                                _ = try? GestaltPatchStore.create(pendingPatchContent)
                                self.refreshPatches()
                            }
                        }
                    } catch {
                        self.report(error)
                        self.isBusy = false
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.report(error)
                    self.isBusy = false
                }
            }
        }
    }

    /// Applies a decoded patch content's fields onto a plist. Throws on
    /// any field parse error so the whole patch is atomic (no half-applied
    /// state).
    private func applyPatchContent(_ content: GestaltPatchContent, to plist: inout GestaltPlist) throws {
        // Accept format versions in 1...current range (old patch files still load).
        // Reject out-of-range versions to avoid undefined behavior.
        let minSupported = 1
        let maxSupported = GestaltPatchContent.formatVersion
        guard content.formatVersion >= minSupported &&
              content.formatVersion <= maxSupported else {
            throw GestaltKitToolError.invalidPatch
        }
        for (key, fv) in content.cacheExtra {
            let kind = PlistValueKind(rawValue: fv.kind) ?? .string
            let value = try PlistValueInfo.parse(fv.encodedValue, as: kind)
            plist.setCacheExtra(value, forKey: key)
        }
    }

    /// Applies an already-loaded library patch on top of the current plist.
    /// parse error aborts the whole patch (no half-applied state gets
    /// persisted), and the error is surfaced instead of silently swallowed.
    func applyPatch(_ patch: GestaltPatch) {
        guard !isBusy, var plist else { return }
        do {
            for (key, fv) in patch.content.cacheExtra {
                let kind = PlistValueKind(rawValue: fv.kind) ?? .string
                let value = try PlistValueInfo.parse(fv.encodedValue, as: kind)
                plist.setCacheExtra(value, forKey: key)
            }
            save(plist, expectedAIRegion: nil)
        } catch {
            report(error)
        }
    }

    func deletePatch(_ patch: GestaltPatch) {
        do {
            try GestaltPatchStore.delete(patch)
        } catch {
            report(error)
        }
        refreshPatches()
    }

    private func save(
        _ pendingPlist: GestaltPlist,
        expectedAIRegion: AIRegionConfiguration?,
        expectedTweaks: Set<GestaltTweakID> = [],
        onComplete: ((Bool) -> Void)? = nil
    ) {
        isBusy = true
        // Don't clear an active risk warning — the user may not have
        // read it yet. It will be replaced if an error occurs.
        if notice?.kind != .riskWarning {
            notice = nil
        }

        // Run the save pipeline off the main actor. Calls are serialized via saveQueue.
        let access = self.access
        let pendingDict = pendingPlist.dict

        saveQueue.async { [weak self] in
            do {
                let originalData = try access.readGestaltData()
                let autoBackup = try GestaltBackupStore.create(from: originalData)
                try access.saveGestalt(pendingDict)
                guard let verification = try access.readGestalt() as? [String: Any] else {
                    throw GestaltKitToolError.invalidPlist
                }
                let verifiedPlist = GestaltPlist(dict: verification)

                // verifyAppliedTweaks: post-write verification that all
                // expected tweak values are present in the re-read plist.
                // Keys known to be daemon-regenerated are skipped.
                if !expectedTweaks.isEmpty {
                    let daemonRegeneratedKeys: Set<String> = [
                        "YlEtTtHlNesRBMal1CqRaA",  // Dynamic Island support flag
                    ]
                    let cacheExtra = verifiedPlist.cacheExtra
                    for id in expectedTweaks {
                        guard let def = GestaltTweakCatalog.definition(for: id) else { continue }
                        for (key, expectedValue) in def.values {
                            if daemonRegeneratedKeys.contains(key) { continue }
                            guard let actualValue = cacheExtra[key] else {
                                throw GestaltKitToolError.verificationFailed
                            }
                            if !Self.valueMatches(expectedValue, actualValue) {
                                throw GestaltKitToolError.verificationFailed
                            }
                        }
                    }
                }

                if let expectedAIRegion {
                    let cacheExtra = verifiedPlist.cacheExtra
                    guard cacheExtra["h63QSdBCiT/z0WU6rdQv6Q"] as? String == "LL",
                          cacheExtra["yK+xavymRGZ3xWc1tb8XDg"] as? String == "LL/A",
                          cacheExtra["97JDvERpVwO+GHtthIh7hA"] as? String == expectedAIRegion.profile.regulatoryModel else {
                        throw GestaltKitToolError.verificationFailed
                    }
                    if expectedAIRegion.requiresDeviceSpoofing {
                        guard cacheExtra["A62OafQ85EJAiiqKn4agtg"] as? Int == 1,
                              cacheExtra["h9jDsbgj7xIVeIQ8S3/X3Q"] as? String == expectedAIRegion.spoofedProductType,
                              cacheExtra["oYicEKzVTz4/CxxE05pEgQ"] as? String == expectedAIRegion.spoofedHardwareModel,
                              cacheExtra["5pYKlGnYYBzGvAlIU8RjEQ"] as? String == expectedAIRegion.spoofedCPUModel else {
                            throw GestaltKitToolError.verificationFailed
                        }
                    }
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.plist = verifiedPlist
                    self.isDirty = false
                    self.syncTogglesFromPlist()
                    self.refreshBackups()
                    self.refreshPatches()
                    self.lastAutoBackup = autoBackup
                    self.isBusy = false
                    self.isRespringing = true
                    onComplete?(true)
                    // Failsafe: if the respring doesn't actually kill the app
                    // (e.g., sandbox restrictions prevent it), auto-dismiss
                    // the overlay after 8 seconds so the user isn't stuck.
                    // cancelled if the view is dismissed during sleep.
                    let respringToken: Int = {
                        self.respringTimeoutToken += 1
                        return self.respringTimeoutToken
                    }()
                    Task.detached { [weak self] in
                        _ = try? await Task.sleep(for: .seconds(8))
                        await MainActor.run {
                            guard let self else { return }
                            if self.isRespringing && self.respringTimeoutToken == respringToken {
                                self.isRespringing = false
                                
                                // didn't happen and they should manually restart
                                // the device for changes to take effect.
                                self.notice = GestaltNotice(
                                    kind: .respringTimeout,
                                    message: String(localized: "The automatic respring did not complete. Please manually restart your device (power off and back on) for changes to take effect.")
                                )
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isDirty = true
                    self.report(error)
                    self.isBusy = false
                    onComplete?(false)
                }
            }
        }
    }

    /// Returns the set of tweaks whose values are currently present in the
    /// plist's CacheExtra. This is used by `applySelectedTweaks()` to
    /// determine which tweaks need to be reverted when toggled OFF.
    private func currentlyAppliedTweaks(in plist: GestaltPlist) -> Set<GestaltTweakID> {
        let cacheExtra = plist.cacheExtra
        var applied: Set<GestaltTweakID> = []
        for definition in GestaltTweakCatalog.definitions {
            let matches = definition.values.allSatisfy { key, expectedValue in
                guard let actualValue = cacheExtra[key] else { return false }
                return actualValueMatches(expectedValue, actualValue)
            }
            if matches {
                applied.insert(definition.id)
            }
        }
        // Mutual exclusion: if both low-perf modes are present (shouldn't
        // happen), keep the "enabled" one.
        if applied.contains(.enableLiquidGlassLowPerformance),
           applied.contains(.disableLiquidGlassLowPerformance) {
            applied.remove(.disableLiquidGlassLowPerformance)
        }
        return applied
    }

    /// Returns the ArtworkDeviceSubType currently stored in the plist, or
    /// nil if not set.
    private func currentDynamicIslandSubtype(in plist: GestaltPlist) -> Int? {
        guard let artwork = plist.cacheExtra["oPeik/9e8lQWMszEjbPzng"] as? [String: Any] else {
            return nil
        }
        return artwork["ArtworkDeviceSubType"] as? Int
    }

    /// Returns the ArtworkDeviceProductDescription currently stored in the
    /// plist, or nil if not set.
    private func currentModelName(in plist: GestaltPlist) -> String? {
        guard let artwork = plist.cacheExtra["oPeik/9e8lQWMszEjbPzng"] as? [String: Any] else {
            return nil
        }
        return artwork["ArtworkDeviceProductDescription"] as? String
    }

    /// Syncs all toggle states from the current plist CacheExtra values.
    /// Called after `load()` and after a successful `save()`.
    private func syncTogglesFromPlist() {
        guard let plist else { return }

        // --- Tweak toggles ---
        selectedTweaks = currentlyAppliedTweaks(in: plist)
        _appliedTweaksCache = selectedTweaks

        // --- Dynamic Island subtype ---
        dynamicIslandSubtype = currentDynamicIslandSubtype(in: plist)
        _appliedSubtypeCache = dynamicIslandSubtype

        // --- Model name ---
        let plistModelName = currentModelName(in: plist)
        if let name = plistModelName, !name.isEmpty {
            changesModelName = true
            modelName = name
        } else {
            changesModelName = false
            modelName = ""
        }
        _appliedModelNameCache = plistModelName

        // --- Siri AI US Region toggle ---
        stagesAIRegion = isAIRegionConfigured
    }

    private func actualValueMatches(_ expected: PlistValue, _ actual: Any) -> Bool {
        Self.valueMatches(expected, actual)
    }

    /// Static value matcher used by both `actualValueMatches` (instance)
    /// and the post-write verification in `save()` (static context).
    static func valueMatches(_ expected: PlistValue, _ actual: Any) -> Bool {
        switch expected {
        case .int(let n):
            // NSNumber bridging: Int(1) from plist vs. Int(1) from definition
            if let actualNumber = actual as? NSNumber {
                return actualNumber.intValue == n
            }
            if let actualInt = actual as? Int {
                return actualInt == n
            }
            return false
        case .double(let d):
            if let actualNumber = actual as? NSNumber {
                return actualNumber.doubleValue == d
            }
            return false
        case .bool(let b):
            if let actualNumber = actual as? NSNumber {
                return actualNumber.boolValue == b
            }
            return false
        case .string(let s):
            return (actual as? String) == s
        case .array(let arr):
            // Array comparison (e.g. iPadApps: [1, 2])
            if let actualArray = actual as? NSArray {
                let expectedArray = arr.map { $0.asAny } as NSArray
                return actualArray.isEqual(expectedArray)
            }
            return false
        case .data(let d):
            return (actual as? Data) == d
        case .date(let dt):
            return (actual as? Date) == dt
        case .dictionary(let dict):
            guard let actualDict = actual as? [String: Any] else { return false }
            for (k, v) in dict {
                guard let actualVal = actualDict[k] else { return false }
                if !valueMatches(v, actualVal) { return false }
            }
            return true
        }
    }

    private func report(_ error: Error) {
        notice = GestaltNotice(kind: .error, message: ErrorHandler.friendlyMessage(for: error))
    }

    // MARK: - Preset Management

    func loadPreset(_ preset: TweakPreset) {
        // Apply tweak IDs from preset
        selectedTweaks = Set(preset.tweaks.compactMap { GestaltTweakID(rawValue: $0) })
        // Apply Dynamic Island subtype
        dynamicIslandSubtype = preset.dynamicIslandSubtype
        // Apply model name
        if !preset.modelName.isEmpty {
            changesModelName = true
            modelName = preset.modelName
        } else {
            changesModelName = false
        }
        // Apply AI Region staging
        stagesAIRegion = preset.stagesAIRegion
        HapticFeedback.selection()
    }

    /// including conflicts with the current selection.
    struct PresetLoadPreview: Identifiable {
        let id = UUID()
        let tweakName: String
        let currentValue: String
        let presetValue: String
        var isConflict: Bool { currentValue != presetValue }
    }

    func presetLoadPreview(_ preset: TweakPreset) -> [PresetLoadPreview] {
        let presetTweaks = Set(preset.tweaks.compactMap { GestaltTweakID(rawValue: $0) })
        let allTweaks = GestaltTweakCatalog.definitions.reduce(into: [GestaltTweakID: String]()) { $0[$1.id] = $1.title }
        var previews: [PresetLoadPreview] = []

        // Tweaks being added (not currently selected)
        for id in presetTweaks.subtracting(selectedTweaks).sorted(by: { $0.rawValue < $1.rawValue }) {
            let title = allTweaks[id] ?? id.rawValue
            previews.append(PresetLoadPreview(tweakName: title, currentValue: String(localized: "Off"), presetValue: String(localized: "On")))
        }
        // Tweaks being removed (currently selected but not in preset)
        for id in selectedTweaks.subtracting(presetTweaks).sorted(by: { $0.rawValue < $1.rawValue }) {
            let title = allTweaks[id] ?? id.rawValue
            previews.append(PresetLoadPreview(tweakName: title, currentValue: String(localized: "On"), presetValue: String(localized: "Off")))
        }
        // Dynamic Island conflict
        if dynamicIslandSubtype != preset.dynamicIslandSubtype {
            let oldVal = dynamicIslandSubtype.map { String(describing: $0) } ?? String(localized: "Default")
            let newVal = preset.dynamicIslandSubtype.map { String(describing: $0) } ?? String(localized: "Default")
            previews.append(PresetLoadPreview(tweakName: String(localized: "Dynamic Island Subtype"), currentValue: oldVal, presetValue: newVal))
        }
        // Model name conflict
        let currentName = changesModelName ? modelName : ""
        if currentName != preset.modelName {
            let oldVal = currentName.isEmpty ? String(localized: "Default") : currentName
            let newVal = preset.modelName.isEmpty ? String(localized: "Default") : preset.modelName
            previews.append(PresetLoadPreview(tweakName: String(localized: "Model Name"), currentValue: oldVal, presetValue: newVal))
        }
        // AI Region conflict
        if stagesAIRegion != preset.stagesAIRegion {
            previews.append(PresetLoadPreview(
                tweakName: String(localized: "AI Region"),
                currentValue: stagesAIRegion ? String(localized: "On") : String(localized: "Off"),
                presetValue: preset.stagesAIRegion ? String(localized: "On") : String(localized: "Off")
            ))
        }
        return previews
    }

    func savePreset(name: String) {
        let preset = TweakPreset(
            id: UUID().uuidString,
            name: name,
            tweaks: selectedTweaks.map { $0.rawValue },
            dynamicIslandSubtype: dynamicIslandSubtype,
            modelName: changesModelName ? modelName : "",
            stagesAIRegion: stagesAIRegion,
            isBuiltIn: false
        )
        PresetStore.addUserPreset(preset)
        HapticFeedback.success()
    }

    func deletePreset(_ preset: TweakPreset) {
        PresetStore.deleteUserPreset(id: preset.id)
        HapticFeedback.impact()
    }

    // MARK: - Status Report

    func generateStatusReport() -> String {
        StatusReportGenerator.generate(
            plist: plist,
            appliedTweaks: _appliedTweaksCache,
            dynamicIslandSubtype: _appliedSubtypeCache,
            modelName: changesModelName ? modelName : nil,
            aiRegionProfile: aiRegionProfile
        )
    }
}

private enum GestaltKitToolError: LocalizedError {
    case invalidPlist
    case invalidBackup
    case invalidPatch
    case verificationFailed
    case emptyModelName
    case modelNameTooLong
    case modelNameInvalidChars

    var errorDescription: String? {
        switch self {
        case .invalidPlist: String(localized: "The MobileGestalt plist is not a valid dictionary.")
        case .invalidBackup: String(localized: "The backup is not a valid MobileGestalt plist.")
        case .invalidPatch: String(localized: "The patch file is invalid or uses an unsupported format version.")
        case .verificationFailed: String(localized: "The MobileGestalt values after writing do not match the expected values.")
        case .emptyModelName: String(localized: "The device model name cannot be empty.")
        case .modelNameTooLong: String(format: String(localized: "Model name too long (max %d characters)."), ModelNameValidator.maxLength)
        case .modelNameInvalidChars: String(localized: "Model name contains invalid characters (allowed: letters, numbers, spaces, -.,()')")
        }
    }
}
