import Foundation
import os

/// Unified logging wrapper backed by os.Logger.
///
/// Usage:
///   GKTLLog.browse.warning("DUPS-REMOVED=\(n)")
///   GKTLLog.nav.error("rollback failed")
///
/// Log levels:
///   - debug:   Debug builds only (auto-filtered in Release)
///   - info:    Normal flow info (visible in Console.app)
///   - warning: Abnormal but recoverable (e.g. dedupe interception, cache miss)
///   - error:   Errors (e.g. XPC failure, timeout)
///
/// Filter by subsystem `com.wesk.gestaltkittool` in Console.app,
/// or by category (Browse/Nav/Crumb/ObjC/Diag).
enum GKTLLog {
    static let subsystem = "com.wesk.gestaltkittool"

    /// File browsing: listDirectory, dedupe, cache, empty-dir-filter
    static let browse = Logger(subsystem: subsystem, category: "Browse")
    /// Navigation stack: navigateInto, navigateBack, rollback
    static let nav = Logger(subsystem: subsystem, category: "Nav")
    /// Breadcrumb view: NOT-A-CHILD, RAW-DUPES warnings
    static let crumb = Logger(subsystem: subsystem, category: "Crumb")
    /// Diagnostics: MobileGestalt Write Test, etc.
    static let diag = Logger(subsystem: subsystem, category: "Diag")
    /// Patches: patch import/export/delete
    static let patch = Logger(subsystem: subsystem, category: "Patch")
    /// Presets: user preset save/load
    static let preset = Logger(subsystem: subsystem, category: "Preset")
    /// Backups: backup create/prune/delete
    static let backup = Logger(subsystem: subsystem, category: "Backup")
}

// MARK: - NSLog replacement

/// Drop-in NSLog replacement. Infers category from `[GKTL-XXX]` prefix.
/// Migrated from NSLog to os.Logger to reduce console noise.
@inline(__always)
func gktlLog(_ format: String) {
    let category = GKTLLogCategory.from(format)
    let logger = Logger(subsystem: GKTLLog.subsystem, category: category)
    logger.notice("\(format, privacy: .public)")
}

@inline(__always)
func gktlLog(_ format: String, _ args: CVarArg...) {
    let message = String(format: format, arguments: args)
    let category = GKTLLogCategory.from(message)
    let logger = Logger(subsystem: GKTLLog.subsystem, category: category)
    logger.notice("\(message, privacy: .public)")
}

private enum GKTLLogCategory {
    static func from(_ message: String) -> String {
        if message.contains("[GKTL-Browse]") { return "Browse" }
        if message.contains("[GKTL-Nav]")    { return "Nav" }
        if message.contains("[GKTL-CRUMB]")  { return "Crumb" }
        if message.contains("[GKTL-ObjC]")   { return "ObjC" }
        if message.contains("[GKTL-Diag]")   { return "Diag" }
        return "Default"
    }
}
