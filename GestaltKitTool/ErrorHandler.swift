//
//  ErrorHandler.swift
//  GestaltKitTool
//

import Foundation

/// Converts low-level NSError objects from BadQueryFileAccess and GestaltAccess
/// into user-friendly localized messages.
enum ErrorHandler {
    /// Returns a user-friendly message for the given error.
    static func friendlyMessage(for error: Error) -> String {
        let nsError = error as NSError

        // Match by domain + code for known BadQueryFileAccess errors.
        if nsError.domain == "com.wesk.vtool.badqueryfile" {
            switch nsError.code {
            case 1:
                return String(localized: "The path must be absolute (start with /).")
            case 2:
                return String(localized: "Sandbox access was denied. The file or directory may be restricted.")
            case 3:
                return String(localized: "Could not read the file. It may not exist or the process lacks permission.")
            case 5:
                return String(localized: "Could not retrieve file metadata. The file may not exist or is inaccessible.")
            default:
                break
            }
        }

        // Match by domain + code for GestaltAccess errors.
        if nsError.domain == "com.wesk.vtool.access" {
            switch nsError.code {
            case 0:
                return String(localized: "This iOS version is not supported.")
            case 1:
                return String(localized: "bad_query is not available on this system.")
            case 2:
                return String(localized: "Failed to acquire sandbox access for the MobileGestalt file.")
            default:
                break
            }
        }

        // NSCocoaErrorDomain — underlying POSIX errors.
        if nsError.domain == NSCocoaErrorDomain {
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            let posixCode = Int32(underlying?.code ?? nsError.code)

            switch posixCode {
            case ENOENT:
                return String(localized: "The file or directory does not exist.")
            case EACCES:
                return String(localized: "Permission denied. The system blocked access to this path.")
            case EIO:
                return String(localized: "An I/O error occurred while reading the file.")
            case ENOTDIR:
                return String(localized: "A component of the path is not a directory.")
            case ELOOP:
                return String(localized: "Too many symbolic links were encountered.")
            case ENAMETOOLONG:
                return String(localized: "The path is too long.")
            default:
                break
            }
        }

        // Fall back to the localized description, or a generic message.
        let desc = nsError.localizedDescription
        if !desc.isEmpty && desc != nsError.domain {
            return desc
        }
        return String(localized: "An unexpected error occurred.")
    }

    /// Returns a short label for a read result status (used by Inspector).
    static func statusLabel(success: Bool) -> String {
        success
            ? String(localized: "Success")
            : String(localized: "Failed")
    }
}
