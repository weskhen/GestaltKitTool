//
//  SystemInspectorModel.swift
//  GestaltKitTool
//
//  Model layer for the System File Inspector.
//  Defines predefined targets for sensitive system files that
//  can be read via bad_query path traversal, and provides
//  read/parsing capabilities.
//

import Combine
import Foundation

// MARK: - System File Target Definition

/// Represents a category of sensitive system files.
enum SystemFileCategory: String, CaseIterable, Identifiable {
    case activation = "Identity & Gestalt"
    case keychain = "System Containers"
    case lockdown = "App Sandboxes"
    case preferences = "Bundle Containers"
    case networkConfig = "Network Configuration"
    case systemInfo = "System Information"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .activation: String(localized: "Identity & Gestalt")
        case .keychain: String(localized: "System Containers")
        case .lockdown: String(localized: "App Sandboxes")
        case .preferences: String(localized: "Bundle Containers")
        case .networkConfig: String(localized: "Network Configuration")
        case .systemInfo: String(localized: "System Information")
        }
    }

    var icon: String {
        switch self {
        case .activation: "person.text.rectangle"
        case .keychain: "shippingbox.fill"
        case .lockdown: "doc.on.doc.fill"
        case .preferences: "cube.box.fill"
        case .networkConfig: "wifi"
        case .systemInfo: "cpu"
        }
    }
}

/// A predefined sensitive system file target.
struct SystemFileTarget: Identifiable {
    let id: String
    let category: SystemFileCategory
    let title: String
    let path: String
    let description: String
    let riskLevel: RiskLevel
    let parser: FileParser

    enum RiskLevel {
        case low, medium, high, critical

        var label: String {
            switch self {
            case .low: String(localized: "Low Risk")
            case .medium: String(localized: "Medium Risk")
            case .high: String(localized: "High Risk")
            case .critical: String(localized: "Critical Risk")
            }
        }

        var color: String {
            switch self {
            case .low: "green"
            case .medium: "yellow"
            case .high: "orange"
            case .critical: "red"
            }
        }

        var icon: String {
            switch self {
            case .low: "checkmark.shield"
            case .medium: "exclamationmark.shield"
            // C-3: `exclamationmark.triangle.shield` does not exist in
            //      the SF Symbol set shipped in iOS 26.x — it triggers a
            //      runtime "No symbol named … found in system symbol set"
            //      console warning and falls back to a question-mark
            //      placeholder, which looks wrong and clutters the log.
            //      `exclamationmark.octagon.fill` (iOS 15+, part of the
            //      "HIG Warnings" palette) has roughly the same visual
            //      semantics: an attention-grabbing shape + exclamation
            //      mark. It is more severe than the .medium shield, so
            //      the low→medium→high→critical severity order is still
            //      visually distinct (circle shield → octagon → square).
            case .high: "exclamationmark.octagon.fill"
            case .critical: "xmark.octagon"
            }
        }
    }

    enum FileParser {
        case plist          // Parse as property list
        case text           // Display as text
        case hex            // Display as hex dump
        case json           // Parse as JSON
        case auto           // Auto-detect
    }
}

// MARK: - System File Result

struct SystemFileResult: Identifiable {
    let id = UUID()
    let target: SystemFileTarget
    let data: Data
    let parsedContent: ParsedContent
    let fileSize: Int64
    let readDate: Date
    let isSuccess: Bool
    let errorMessage: String?

    enum ParsedContent {
        case plist([String: Any])
        case text(String)
        case hex(String)
        case json(Any)
        case binary(Data)
        case error(String)
    }

    /// A human-readable summary of the parsed content.
    var summary: String {
        if !isSuccess {
            return errorMessage ?? String(localized: "Read failed")
        }
        switch parsedContent {
        case .plist(let dict):
            return String(format: String(localized: "Property List (%d keys)"), dict.count)
        case .text(let text):
            let lines = text.components(separatedBy: "\n").count
            return String(format: String(localized: "Text (%d lines, %d bytes)"), lines, data.count)
        case .hex:
            return String(format: String(localized: "Hex dump (%d bytes)"), data.count)
        case .json:
            return String(format: String(localized: "JSON (%d bytes)"), data.count)
        case .binary:
            return String(format: String(localized: "Binary data (%d bytes)"), data.count)
        case .error(let msg):
            return msg
        }
    }
}

// MARK: - System Inspector Model

@MainActor
final class SystemInspectorModel: ObservableObject {
    @Published var results: [SystemFileResult] = []
    @Published var isLoading = false
    @Published var loadingTargetId: String?
    @Published var errorMessage: String?

    private let fileAccess = BadQueryFileAccess.shared()

    /// All predefined system file targets, organized by category.
    /// Limited to paths accessible via bad_query sandbox escape:
    ///   /var/containers/Shared/SystemGroup/*
    ///   /var/mobile/Containers/Data/Application/*
    ///   /var/mobile/Containers/Shared/AppGroup/*
    static let targets: [SystemFileTarget] = [
        // --- MobileGestalt & Identity ---
        .init(
            id: "mobilegestalt_cache",
            category: .activation,
            title: "MobileGestalt Cache",
            path: "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist",
            description: String(localized: "MobileGestalt cache containing device identity and capability flags."),
            riskLevel: .high,
            parser: .plist
        ),
        .init(
            id: "mobilegestalt_dir",
            category: .activation,
            title: "MobileGestalt Cache Directory",
            path: "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches",
            description: String(localized: "Directory listing of the MobileGestalt system group cache folder."),
            riskLevel: .medium,
            parser: .auto
        ),
        .init(
            id: "mobilegestalt_systemgroup",
            category: .activation,
            title: "MobileGestalt SystemGroup Root",
            path: "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache",
            description: String(localized: "Root directory of the MobileGestalt system group container."),
            riskLevel: .medium,
            parser: .auto
        ),

        // --- System Group Containers ---
        .init(
            id: "systemgroup_root",
            category: .keychain,
            title: "SystemGroup Containers",
            path: "/var/containers/Shared/SystemGroup",
            description: String(localized: "Listing of all system group containers on the device."),
            riskLevel: .medium,
            parser: .auto
        ),
        .init(
            id: "system_data_root",
            category: .keychain,
            title: "System Data Containers",
            path: "/var/containers/Data/System",
            description: String(localized: "System data containers (iOS 27). Contains daemon sandboxes."),
            riskLevel: .high,
            parser: .auto
        ),

        // --- App Sandboxes ---
        .init(
            id: "app_containers",
            category: .lockdown,
            title: "App Data Containers",
            path: "/var/mobile/Containers/Data/Application",
            description: String(localized: "Listing of all app data container UUIDs."),
            riskLevel: .medium,
            parser: .auto
        ),
        .init(
            id: "appgroup_containers",
            category: .lockdown,
            title: "App Group Containers",
            path: "/var/mobile/Containers/Shared/AppGroup",
            description: String(localized: "Listing of all app group container UUIDs."),
            riskLevel: .medium,
            parser: .auto
        ),
        .init(
            id: "internaldaemon_containers",
            category: .lockdown,
            title: "InternalDaemon Containers",
            path: "/var/mobile/Containers/Data/InternalDaemon",
            description: String(localized: "Internal daemon data containers."),
            riskLevel: .high,
            parser: .auto
        ),
        .init(
            id: "pluginkit_containers",
            category: .lockdown,
            title: "PluginKit Plugin Containers",
            path: "/var/mobile/Containers/Data/PluginKitPlugin",
            description: String(localized: "PluginKit plugin data containers."),
            riskLevel: .high,
            parser: .auto
        ),

        // --- Bundle Containers ---
        .init(
            id: "bundle_containers",
            category: .preferences,
            title: "App Bundle Containers",
            path: "/var/containers/Bundle/Application",
            description: String(localized: "Listing of installed app bundle containers."),
            riskLevel: .medium,
            parser: .auto
        ),
    ]

    /// Groups targets by category for display.
    /// Computed once and cached — the target list is static and never
    /// changes at runtime, so there's no need to recompute on every
    /// SwiftUI body re-render.
    static let groupedTargets: [(category: SystemFileCategory, targets: [SystemFileTarget])] = {
        SystemFileCategory.allCases
            .map { category in
                (category, targets.filter { $0.category == category })
            }
            .filter { !$0.targets.isEmpty }
    }()

    // MARK: - File Reading

    func readTarget(_ target: SystemFileTarget) {
        guard !isLoading else { return }
        isLoading = true
        loadingTargetId = target.id
        errorMessage = nil

        let fileAccess = self.fileAccess
        let targetPath = target.path
        let targetParser = target.parser

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // First, try to stat the path to check if it's a directory.
            let statResult: BQFileEntry?
            do {
                statResult = try fileAccess.statFile(atPath: targetPath)
            } catch {
                statResult = nil
            }

            if let statResult, statResult.isDirectory {
                // It's a directory — list its contents instead of reading.
                var listError: NSError?
                let entries = fileAccess.listDirectory(atPath: targetPath, error: &listError)

                if let listError {
                    let friendly = ErrorHandler.friendlyMessage(for: listError)
                    let result = SystemFileResult(
                        target: target, data: Data(), parsedContent: .error(friendly),
                        fileSize: 0, readDate: Date(), isSuccess: false,
                        errorMessage: friendly
                    )
                    Task { @MainActor [weak self] in
                        self?.storeResult(result, for: target.id)
                    }
                    return
                }

                let dirListing = entries.map { entry -> String in
                    var line = entry.isDirectory ? "[DIR]  " : "       "
                    line += entry.name
                    if !entry.isDirectory {
                        line += "  (\(ByteCountFormatter.string(fromByteCount: entry.fileSize, countStyle: .file)))"
                    }
                    return line
                }.joined(separator: "\n")

                let dirData = dirListing.data(using: .utf8) ?? Data()
                let result = SystemFileResult(
                    target: target,
                    data: dirData,
                    parsedContent: .text(dirListing),
                    fileSize: Int64(dirData.count),
                    readDate: Date(),
                    isSuccess: true,
                    errorMessage: nil
                )

                Task { @MainActor [weak self] in
                    self?.storeResult(result, for: target.id)
                }
                return
            }

            // It's a file — read its contents.
            do {
                let data = try fileAccess.readFile(atPath: targetPath)
                let content = Self.parseStatic(data: data, parser: targetParser)

                let result = SystemFileResult(
                    target: target,
                    data: data,
                    parsedContent: content,
                    fileSize: Int64(data.count),
                    readDate: Date(),
                    isSuccess: true,
                    errorMessage: nil
                )

                Task { @MainActor [weak self] in
                    self?.storeResult(result, for: target.id)
                }
            } catch {
                let friendly = ErrorHandler.friendlyMessage(for: error)
                let result = SystemFileResult(
                    target: target, data: Data(),
                    parsedContent: .error(friendly),
                    fileSize: 0, readDate: Date(), isSuccess: false,
                    errorMessage: friendly
                )
                Task { @MainActor [weak self] in
                    self?.storeResult(result, for: target.id)
                }
            }
        }
    }

    private func storeResult(_ result: SystemFileResult, for targetId: String) {
        results.removeAll { $0.target.id == targetId }
        results.insert(result, at: 0)
        isLoading = false
        loadingTargetId = nil
    }

    // MARK: - Parsing (static, safe for background threads)

    nonisolated private static func parseStatic(data: Data, parser: SystemFileTarget.FileParser) -> SystemFileResult.ParsedContent {
        switch parser {
        case .plist:
            var format = PropertyListSerialization.PropertyListFormat.binary
            if let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: &format
            ) as? [String: Any] {
                return .plist(plist)
            }
            // Fall back to text if plist parsing fails.
            if let text = String(data: data, encoding: .utf8) {
                return .text(text)
            }
            return .error(String(localized: "Unable to parse as property list."))

        case .text:
            if let text = String(data: data, encoding: .utf8) {
                return .text(text)
            }
            return .hex(data.prefix(8192).map { String(format: "%02x", $0) }
                .chunked(into: 16).map { $0.joined(separator: " ") }
                .joined(separator: "\n"))

        case .hex:
            let hex = data.prefix(8192).map { String(format: "%02x", $0) }
                .chunked(into: 16).map { $0.joined(separator: " ") }
                .joined(separator: "\n")
            return .hex(hex)

        case .json:
            if let json = try? JSONSerialization.jsonObject(with: data) {
                return .json(json)
            }
            return .error(String(localized: "Unable to parse as JSON."))

        case .auto:
            // Try plist first, then JSON, then text, then hex.
            var format = PropertyListSerialization.PropertyListFormat.binary
            if let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: &format
            ) as? [String: Any] {
                return .plist(plist)
            }
            if let json = try? JSONSerialization.jsonObject(with: data) {
                return .json(json)
            }
            if let text = String(data: data, encoding: .utf8) {
                return .text(text)
            }
            let hex = data.prefix(8192).map { String(format: "%02x", $0) }
                .chunked(into: 16).map { $0.joined(separator: " ") }
                .joined(separator: "\n")
            return .hex(hex)
        }
    }
}
