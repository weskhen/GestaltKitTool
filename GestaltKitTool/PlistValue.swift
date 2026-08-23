//
//  PlistValue.swift
//  GestaltKitTool
//
//  Type-safe representation of property list values, shared by
//  PlistViewerView, SystemInspectorView, and AdvancedGestaltEditorView.
//

import Foundation

/// Type-safe representation of a property list value.
/// Maps directly to the types supported by `PropertyListSerialization`.
enum PlistValue: Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case data(Data)
    case date(Date)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    /// Converts a typed `PlistValue` back to the `Any` representation
    /// needed by `PropertyListSerialization`.
    var asAny: Any {
        switch self {
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .data(let v): return v
        case .date(let v): return v
        case .array(let v): return v.map { $0.asAny }
        case .dictionary(let v):
            return v.mapValues { $0.asAny }
        }
    }

    /// Attempts to wrap an `Any` (from PropertyListSerialization) into a `PlistValue`.
    /// Returns `nil` for types not representable in a plist.
    static func wrap(_ any: Any) -> PlistValue? {
        switch any {
        case let v as Bool: return .bool(v)
        case let v as Int: return .int(v)
        case let v as Double: return .double(v)
        case let v as Float: return .double(Double(v))
        case let v as String: return .string(v)
        case let v as Data: return .data(v)
        case let v as Date: return .date(v)
        case let v as [Any]:
            let mapped = v.compactMap { wrap($0) }
            return mapped.count == v.count ? .array(mapped) : nil
        case let v as [String: Any]:
            var dict: [String: PlistValue] = [:]
            for (k, val) in v {
                guard let wrapped = wrap(val) else { return nil }
                dict[k] = wrapped
            }
            return .dictionary(dict)
        default:
            // NSNumber can be bool, int, or double — check more carefully.
            if let num = any as? NSNumber {
                let typeStr = String(cString: num.objCType)
                switch typeStr {
                case "c", "B": return .bool(num.boolValue)
                case "s", "i", "l", "q", "S", "I", "L", "Q": return .int(num.intValue)
                case "f", "d": return .double(num.doubleValue)
                default: return nil
                }
            }
            return nil
        }
    }

    /// Human-readable description for display in viewer rows.
    var displayDescription: String {
        switch self {
        case .bool(let v): return v ? "true" : "false"
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let v): return "\"\(v)\""
        case .data(let d):
            let hex = d.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
            let suffix = d.count > 32 ? "… (\(d.count) bytes)" : " (\(d.count) bytes)"
            return hex + suffix
        case .date(let d):
            return ISO8601DateFormatter().string(from: d)
        case .array(let arr):
            return "[\(arr.count) items]"
        case .dictionary(let dict):
            return "{\(dict.count) keys}"
        }
    }

    /// Whether this value is a container (array or dictionary) that can be expanded.
    var isExpandable: Bool {
        switch self {
        case .array, .dictionary: return true
        default: return false
        }
    }
}
