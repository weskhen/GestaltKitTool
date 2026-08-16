//
//  FileTypeRegistry.swift
//  GestaltKitTool
//
//  Centralized file-type classification, icon, color, and label
//  resolution. Eliminates duplicated switch statements that were
//  scattered across FileExplorerView and FileExplorerModel.
//

import SwiftUI
import Foundation

enum FileKind: String {
    case plist
    case json
    case database
    case text
    case image
    case xml
    case binary

    var localizedLabel: String {
        switch self {
        case .plist:   return String(localized: "Property List")
        case .json:    return String(localized: "JSON")
        case .database: return String(localized: "SQLite Database")
        case .text:    return String(localized: "Text")
        case .image:   return String(localized: "Image")
        case .xml:     return String(localized: "XML")
        case .binary:  return String(localized: "Binary Data")
        }
    }
}

enum FileTypeRegistry {

    // MARK: - Classification

    /// Classifies a file by extension, falling back to magic-byte
    /// detection and UTF-8 plaintext probing.
    static func classify(fileName: String, data: Data) -> FileKind {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if let kind = classify(extension: ext) {
            return kind
        }
        return classifyByMagic(data: data)
    }

    /// Extension-only classification (no data read required).
    static func classify(extension ext: String) -> FileKind? {
        switch ext.lowercased() {
        case "plist":   return .plist
        case "json":    return .json
        case "sqlite", "db": return .database
        case "txt", "log": return .text
        case "png", "jpg", "jpeg", "gif", "heic": return .image
        case "xml":     return .xml
        default:        return nil
        }
    }

    /// Magic-byte detection for unknown extensions.
    static func classifyByMagic(data: Data) -> FileKind {
        // Binary plist: "bplist00"
        if data.count >= 8,
           data.prefix(8) == Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30]) {
            return .plist
        }
        // SQLite: "SQLite format 3\0"
        if data.count >= 16,
           data.prefix(16) == Data("SQLite format 3\0".utf8) {
            return .database
        }
        if data.count >= 4 {
            let magic = data.prefix(4)
            if magic == Data([0x89, 0x50, 0x4E, 0x47]) { return .image } // PNG
            if magic.prefix(2) == Data([0xFF, 0xD8]) { return .image }   // JPEG
        }
        if String(data: data, encoding: .utf8) != nil { return .text }
        return .binary
    }

    // MARK: - Visuals

    static func icon(for kind: FileKind) -> String {
        switch kind {
        case .plist:   return "doc.text.fill"
        case .json:    return "curlybraces.fill"
        case .database: return "cylinder.split.1x2.fill"
        case .text:    return "doc.plaintext.fill"
        case .image:   return "photo.fill"
        case .xml:     return "doc.richtext.fill"
        case .binary:  return "doc.fill"
        }
    }

    static func color(for kind: FileKind) -> Color {
        switch kind {
        case .plist:   return .purple
        case .json:    return .orange
        case .database: return .brown
        case .text:    return .secondary
        case .image:   return .pink
        case .xml:     return .teal
        case .binary:  return .gray
        }
    }

    /// Detailed label for a specific extension (e.g. "PNG Image").
    static func detailedLabel(for ext: String) -> String {
        switch ext.lowercased() {
        case "plist":   return String(localized: "Property List")
        case "json":    return String(localized: "JSON")
        case "sqlite", "db": return String(localized: "SQLite Database")
        case "txt", "log": return String(localized: "Text")
        case "png":     return String(localized: "PNG Image")
        case "jpg", "jpeg": return String(localized: "JPEG Image")
        case "heic":    return String(localized: "HEIC Image")
        case "gif":     return String(localized: "GIF Image")
        case "xml":     return String(localized: "XML")
        default:        return String(localized: "File")
        }
    }

}
