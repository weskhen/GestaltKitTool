//
//  ModelNameValidator.swift
//  GestaltKitTool
//
//  Prevents plist corruption / system UI breakage from oversized
//  or control-character model names. Used by both the UI TextField
//  (real-time feedback) and the CLI --set-model-name command.
//

import Foundation

enum ModelNameValidator {
    /// Maximum allowed character count for model names.
    static let maxLength = 50

    /// Allowed character set: alphanumerics, whitespace, and `-.,()'`
    static let allowedCharacters: CharacterSet = .alphanumerics
        .union(.whitespaces)
        .union(CharacterSet(charactersIn: "-.,()'"))

    /// Validation result for a model name string.
    enum Result: Equatable {
        case ok
        case empty
        case tooLong
        case invalidCharacters

        /// Whether this result represents a valid name.
        var isValid: Bool { self == .ok }

        /// Localized user-facing message for non-OK results.
        var localizedMessage: String {
            switch self {
            case .ok:
                return ""
            case .empty:
                return String(localized: "The device model name cannot be empty.")
            case .tooLong:
                return String(format: String(localized: "Model name too long (max %d characters)."), maxLength)
            case .invalidCharacters:
                return String(localized: "Model name contains invalid characters (allowed: letters, numbers, spaces, -.,()')")
            }
        }
    }

    /// Validates a model name string.
    /// - Parameter name: The raw input string.
    /// - Returns: `.ok` if valid, otherwise the specific failure reason.
    static func validate(_ name: String) -> Result {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.count > maxLength { return .tooLong }
        if !trimmed.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) {
            return .invalidCharacters
        }
        return .ok
    }

    /// Returns a sanitized version of the name by stripping
    /// disallowed characters and truncating to `maxLength`.
    /// Useful for real-time TextField filtering.
    static func sanitized(_ name: String) -> String {
        let filtered = String(name.unicodeScalars.filter { allowedCharacters.contains($0) })
        return String(filtered.prefix(maxLength))
    }
}
