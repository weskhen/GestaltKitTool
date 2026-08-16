import Combine
import Foundation

// CR-14: GestaltAccess is an ObjC class whose state is fully guarded by
// its internal serial queues (_stateQueue for config, workQueue for
// XPC + I/O). All public methods are safe to call from any thread, so
// claiming @unchecked Sendable here lets background dispatch closures
// capture it without warnings.
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
    /// Monotonically incremented each time a respring timeout is scheduled.
    /// Used to cancel a stale timeout if a new save happens before the old
    /// timeout fires.
    private var respringTimeoutToken = 0

    private let access = GestaltAccess.shared()

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

    func load() {
        guard !isBusy else { return }
        hasAttemptedLoad = true
        isBusy = true
        isRespringing = false
        notice = nil

        // CR-14: run connect + plist read OFF the main actor. The old
        // synchronous version blocked the main thread through
        // connectWithError's semaphore wait (up to 15 s when
        // ContainerManager is slow) plus the plist file I/O.
        let access = self.access
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
            if changesModelName && uiModelName.isEmpty {
                throw GestaltKitToolError.emptyModelName
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
            save(pending, expectedAIRegion: expectedConfiguration)
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

    func createBackup() {
        guard !isBusy else { return }
        isBusy = true

        // CR-14: XPC + file I/O off the main actor (same rationale
        // as load()).
        let access = self.access
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try access.connect()
                let data = try access.readGestaltData()
                let backup = try GestaltBackupStore.create(from: data)
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
        defer { isBusy = false }

        let accessed = url.startAccessingSecurityScopedResource()
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
            let backup = try GestaltBackupStore.create(from: data)
            refreshBackups()
            notice = GestaltNotice(
                kind: .backupCreated,
                message: String(
                    format: String(localized: "Imported %@ and saved it as %@.plist."),
                    url.lastPathComponent,
                    backup.name
                )
            )
        } catch {
            report(error)
        }
    }

    func restore(_ backup: GestaltBackup) {
        guard !isBusy else { return }
        do {
            let data = try GestaltBackupStore.data(for: backup)
            var format = PropertyListSerialization.PropertyListFormat.binary
            guard let dictionary = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &format
            ) as? [String: Any] else {
                throw GestaltKitToolError.invalidBackup
            }
            save(GestaltPlist(dict: dictionary), expectedAIRegion: nil)
        } catch {
            report(error)
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
        patches = (try? GestaltPatchStore.list()) ?? []
    }

    // MARK: - Patches

    /// Exports the given CacheExtra keys from the current plist as a
    /// shareable `.weskpatch`. Only the selected keys are written into
    /// the patch, so it stays device-independent.
    func exportPatch(name: String, author: String?, notes: String?, keys: [String]) {
        guard !isBusy, let plist else { return }
        isBusy = true
        defer { isBusy = false }

        let cacheExtra = plist.cacheExtra
        var fieldValues: [String: GestaltPatchContent.FieldValue] = [:]
        var skippedKeys: [String] = []
        for key in keys {
            guard let value = cacheExtra[key] else { continue }
            let kind = PlistValueKind.kind(of: value)
            let encoded = PlistValueInfo.encode(value, as: kind)
            // M-3 fix: if encode returns "" (happens for invalid plist
            // objects such as NSDictionary containing NSDate / NSData
            // that can't be JSON-serialized), skip the field instead of
            // storing an empty string — because parse("", as: .data)
            // succeeds and returns empty Data, which is semantically
            // wrong (differs from the original value).
            guard !encoded.isEmpty else {
                skippedKeys.append(key)
                continue
            }
            fieldValues[key] = .init(kind: kind.rawValue, encodedValue: encoded)
        }

        guard !fieldValues.isEmpty else {
            notice = GestaltNotice(
                kind: .error,
                message: String(localized: "No matching CacheExtra keys to export.")
            )
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
            refreshPatches()
            let base = String(
                format: String(localized: "Exported patch %@ (%d fields)."),
                name, fieldValues.count
            )
            let tail = skippedKeys.isEmpty
                ? ""
                : " " + String(
                    format: String(localized: "(%d unencodable fields skipped.)"),
                    skippedKeys.count)
            notice = GestaltNotice(kind: .backupCreated, message: base + tail)
        } catch {
            report(error)
        }
    }

    /// Imports a `.weskpatch` from a user-selected URL, applies it on top
    /// of the current plist, and saves. A copy is also stored in the
    /// patch library for re-use. `save()` manages isBusy, backup,
    /// verification, and respring.
    func importPatch(from url: URL) {
        guard !isBusy, var plist else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let content = try JSONDecoder().decode(GestaltPatchContent.self, from: data)
            // M-2 fix: accept any supported format version (1...current) so
            // older patch files continue to work when we bump the format,
            // and reject newer / out-of-range versions to avoid undefined
            // decoding.
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
            _ = try? GestaltPatchStore.create(content)
            refreshPatches()
            save(plist, expectedAIRegion: nil)
        } catch {
            report(error)
        }
    }

    /// Applies an already-loaded library patch on top of the current plist.
    /// H-3 fix: consistent failure semantics with importPatch — any field
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
        try? GestaltPatchStore.delete(patch)
        refreshPatches()
    }

    private func save(
        _ pendingPlist: GestaltPlist,
        expectedAIRegion: AIRegionConfiguration?
    ) {
        isBusy = true
        // Don't clear an active risk warning — the user may not have
        // read it yet. It will be replaced if an error occurs.
        if notice?.kind != .riskWarning {
            notice = nil
        }

        // CR-14: run the whole save pipeline OFF the main actor. The
        // old synchronous version executed readGestaltData +
        // backup-create + saveGestalt + verification read on the main
        // thread — 4 lease acquisitions (each with a semaphore-bounded
        // XPC call) plus plist I/O, freezing the UI for the duration.
        let access = self.access
        let pendingDict = pendingPlist.dict

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        do {
            let originalData = try access.readGestaltData()
            _ = try GestaltBackupStore.create(from: originalData)
            try access.saveGestalt(pendingDict)
            guard let verification = try access.readGestalt() as? [String: Any] else {
                throw GestaltKitToolError.invalidPlist
            }
            let verifiedPlist = GestaltPlist(dict: verification)

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
                self.isBusy = false
                self.isRespringing = true
                // Failsafe: if the respring doesn't actually kill the app
                // (e.g., sandbox restrictions prevent it), auto-dismiss
                // the overlay after 8 seconds so the user isn't stuck.
                let respringToken: Int = {
                    self.respringTimeoutToken += 1
                    return self.respringTimeoutToken
                }()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    await MainActor.run {
                        guard let self else { return }
                        if self.isRespringing && self.respringTimeoutToken == respringToken {
                            self.isRespringing = false
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

    private func actualValueMatches(_ expected: Any, _ actual: Any) -> Bool {
        // NSNumber bridging: Int(1) from plist vs. Int(1) from definition
        if let expectedNumber = expected as? NSNumber,
           let actualNumber = actual as? NSNumber {
            return expectedNumber == actualNumber
        }
        // String comparison
        if let expectedString = expected as? String,
           let actualString = actual as? String {
            return expectedString == actualString
        }
        // Array comparison (e.g. iPadApps: [1, 2])
        if let expectedArray = expected as? NSArray,
           let actualArray = actual as? NSArray {
            return expectedArray.isEqual(actualArray)
        }
        // Fallback
        return false
    }

    private func report(_ error: Error) {
        notice = GestaltNotice(kind: .error, message: error.localizedDescription)
    }
}

private enum GestaltKitToolError: LocalizedError {
    case invalidPlist
    case invalidBackup
    case invalidPatch
    case verificationFailed
    case emptyModelName

    var errorDescription: String? {
        switch self {
        case .invalidPlist: String(localized: "The MobileGestalt plist is not a valid dictionary.")
        case .invalidBackup: String(localized: "The backup is not a valid MobileGestalt plist.")
        case .invalidPatch: String(localized: "The patch file is invalid or uses an unsupported format version.")
        case .verificationFailed: String(localized: "The MobileGestalt values after writing do not match the expected values.")
        case .emptyModelName: String(localized: "The device model name cannot be empty.")
        }
    }
}
