//
//  WeskToolEnhancements.swift
//  GestaltKitTool
//
//  Centralized enhancement infrastructure:
//  - Backup labels (UserDefaults-backed)
//  - Backup metadata (auto vs manual, integrity check)
//  - Tweak presets (built-in + user-defined, Codable)
//  - Haptic feedback helper
//  - Change summary generator
//  - Status report generator
//

import Foundation
import SwiftUI
import os
import UIKit

// MARK: - Backup Labels 
enum BackupLabelStore {
    private static let defaults = UserDefaults.standard
    private static let keyPrefix = "backup_label_"

    static func label(for backupName: String) -> String? {
        defaults.string(forKey: keyPrefix + backupName)
    }

    static func setLabel(_ label: String?, for backupName: String) {
        let key = keyPrefix + backupName
        if let label, !label.isEmpty {
            defaults.set(label, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Backup Metadata (Auto/Manual, Integrity)

enum BackupMeta {
    /// list doesn't re-read every plist file on every SwiftUI body
    /// re-evaluation.
    private static var integrityCache: [URL: Bool] = [:]
    private static let integrityLock = NSLock()
    /// Checks whether a backup file is a valid plist with a CacheExtra dict.
    static func isIntact(url: URL) -> Bool {
        integrityLock.lock()
        defer { integrityLock.unlock() }
        if let cached = integrityCache[url] {
            return cached
        }
        guard let data = try? Data(contentsOf: url) else {
            integrityCache[url] = false
            return false
        }
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            integrityCache[url] = false
            return false
        }
        let result = plist["CacheExtra"] is [String: Any]
        integrityCache[url] = result
        return result
    }

    /// Clear the integrity cache (called on memory pressure or when
    /// the backup list is refreshed).
    static func clearCache() {
        integrityLock.lock()
        integrityCache.removeAll()
        integrityLock.unlock()
    }
}

// MARK: - Tweak Presets (Save/Load, Built-in)

struct TweakPreset: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var tweaks: [String]        // GestaltTweakID raw values
    var dynamicIslandSubtype: Int?
    var modelName: String
    var stagesAIRegion: Bool
    var isBuiltIn: Bool

    static let builtIn: [TweakPreset] = [
        .init(
            id: "builtin-iphone-air",
            name: String(localized: "iPhone Air Look"),
            tweaks: [],
            dynamicIslandSubtype: 2736,
            modelName: "iPhone Air",
            stagesAIRegion: false,
            isBuiltIn: true
        ),
        .init(
            id: "builtin-ipad-mode",
            name: String(localized: "iPad Mode on iPhone"),
            tweaks: ["stageManager", "iPadApps"],
            dynamicIslandSubtype: nil,
            modelName: "",
            stagesAIRegion: false,
            isBuiltIn: true
        ),
        .init(
            id: "builtin-minimal",
            name: String(localized: "Minimal Tweaks"),
            tweaks: ["bootChime", "chargeLimit"],
            dynamicIslandSubtype: nil,
            modelName: "",
            stagesAIRegion: false,
            isBuiltIn: true
        ),
        .init(
            id: "builtin-full-spoof",
            name: String(localized: "Full Spoof"),
            tweaks: ["supportsDynamicIsland", "bootChime"],
            dynamicIslandSubtype: 2622,
            modelName: "iPhone 16 Pro",
            stagesAIRegion: true,
            isBuiltIn: true
        ),
    ]
}

enum PresetStore {
    private static let key = "user_tweak_presets"

    // so all cached @State copies can refresh.
    static let didChangeNotification = Notification.Name("GKTLUserPresetsDidChange")

    static func loadUserPresets() -> [TweakPreset] {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return []
        }
        do {
            return try JSONDecoder().decode([TweakPreset].self, from: data)
        } catch {
            // visible to the user via Console, not silently swallowed.
            GKTLLog.preset.error("loadUserPresets decode failed: \(error.localizedDescription)")
            return []
        }
    }

    static func saveUserPresets(_ presets: [TweakPreset]) {
        do {
            let data = try JSONEncoder().encode(presets)
            UserDefaults.standard.set(data, forKey: key)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        } catch {
            GKTLLog.preset.error("saveUserPresets encode failed: \(error.localizedDescription)")
        }
    }

    static func addUserPreset(_ preset: TweakPreset) {
        var presets = loadUserPresets()
        presets.append(preset)
        saveUserPresets(presets)
    }

    static func deleteUserPreset(id: String) {
        var presets = loadUserPresets()
        presets.removeAll { $0.id == id }
        saveUserPresets(presets)
    }
}

// MARK: - Haptic Feedback 
enum HapticFeedback {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

// MARK: - Status Report 
enum StatusReportGenerator {
    static func generate(
        plist: GestaltPlist?,
        appliedTweaks: Set<GestaltTweakID>,
        dynamicIslandSubtype: Int?,
        modelName: String?,
        aiRegionProfile: AIRegionProfile?
    ) -> String {
        var lines: [String] = []
        let build = GestaltAccess.currentOSBuild()
        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        let versionStr = "\(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)"
        lines.append("GestaltKitTool Status Report")
        lines.append(String(repeating: "=", count: 30))
        lines.append("iOS: \(versionStr) (Build \(build.isEmpty ? "Unknown" : build))")

        if let profile = aiRegionProfile {
            lines.append("AI Region: \(profile.marketingName) (\(profile.regulatoryModel))")
        } else {
            lines.append("AI Region: Not configured")
        }

        if let subtype = dynamicIslandSubtype,
           let option = DynamicIslandOption.all.first(where: { $0.subtype == subtype }) {
            lines.append("Dynamic Island: \(option.title) (subtype \(subtype))")
        } else {
            lines.append("Dynamic Island: Not set")
        }

        if let modelName, !modelName.isEmpty {
            lines.append("Model Name: \(modelName)")
        } else {
            lines.append("Model Name: Not changed")
        }

        lines.append("")
        lines.append("Applied Tweaks:")
        if appliedTweaks.isEmpty {
            lines.append("  (none)")
        } else {
            for id in appliedTweaks.sorted(by: { $0.rawValue < $1.rawValue }) {
                if let def = GestaltTweakCatalog.definition(for: id) {
                    lines.append("  - \(def.title)")
                }
            }
        }

        let allTweakIDs = Set(GestaltTweakCatalog.definitions.map { $0.id })
        let notApplied = allTweakIDs.subtracting(appliedTweaks)
        lines.append("")
        lines.append("Not Applied:")
        for id in notApplied.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let def = GestaltTweakCatalog.definition(for: id) {
                lines.append("  - \(def.title)")
            }
        }

        lines.append("")
        lines.append("Generated: \(Date())")
        return lines.joined(separator: "\n")
    }
}
