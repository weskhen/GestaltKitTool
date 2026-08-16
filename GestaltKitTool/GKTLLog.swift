import Foundation
import os

/// 统一日志封装 — 基于 os.Logger
///
/// 用法:
///   GKTLLog.browse.warning("DUPS-REMOVED=\(n)")
///   GKTLLog.nav.error("rollback failed")
///
/// 日志级别:
///   - debug:   仅 Debug 构建输出 (Release 自动过滤)
///   - info:    正常流程信息 (Console.app 可见)
///   - warning: 异常但可恢复 (如 dedupe 拦截、cache miss)
///   - error:   错误 (如 XPC 失败、timeout)
///
/// 在 Console.app 中按 subsystem `com.wesk.gestaltkittool` 过滤,
/// 或按 category (Browse/Nav/Crumb/ObjC/Diag) 细分查看。
enum GKTLLog {
    static let subsystem = "com.wesk.gestaltkittool"

    /// 文件浏览: listDirectory, dedupe, cache, empty-dir-filter
    static let browse = Logger(subsystem: subsystem, category: "Browse")
    /// 导航栈: navigateInto, navigateBack, rollback, REBASE
    static let nav = Logger(subsystem: subsystem, category: "Nav")
    /// Breadcrumb 视图: NOT-A-CHILD, RAW-DUPES 告警
    static let crumb = Logger(subsystem: subsystem, category: "Crumb")
    /// 诊断: MobileGestalt Write Test 等
    static let diag = Logger(subsystem: subsystem, category: "Diag")
}

// MARK: - NSLog Drop-in Replacement

/// NSLog 的统一替代函数。
///
/// - Debug 构建: 调用 NSLog (Xcode console 直接可见, 带 emoji 前缀)
/// - Release 构建: 调用 os_log (性能更好, Console.app 可过滤)
///
/// 用法与 NSLog 完全相同, 只需把 `NSLog(` 替换为 `gktlLog(`:
///   gktlLog("[GKTL-Browse] ⚠️ DUPS-REMOVED=\(n)")
///
/// 自动从 `[GKTL-XXX]` 前缀推断 category:
///   [GKTL-Browse] → Browse
///   [GKTL-Nav]    → Nav
///   [GKTL-Crumb]  → Crumb
///   [GKTL-ObjC]   → ObjC
///   其他          → Default
@inline(__always)
func gktlLog(_ format: String) {
    let category = GKTLLogCategory.from(format)
    #if DEBUG
    NSLog("%@", format)
    #else
    let log = OSLog(subsystem: GKTLLog.subsystem, category: category)
    os_log("%{public}@", log: log, type: .default, format)
    #endif
}

@inline(__always)
func gktlLog(_ format: String, _ args: CVarArg...) {
    let message = String(format: format, arguments: args)
    let category = GKTLLogCategory.from(message)
    #if DEBUG
    NSLog("%@", message)
    #else
    let log = OSLog(subsystem: GKTLLog.subsystem, category: category)
    os_log("%{public}@", log: log, type: .default, message)
    #endif
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
