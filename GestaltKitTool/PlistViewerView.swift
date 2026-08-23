//
//  PlistViewerView.swift
//  GestaltKitTool
//
//  Recursive property list viewer with search and expand/collapse.
//

import SwiftUI

// MARK: - Plist Viewer

struct PlistViewerView: View {
    let preview: FilePreview
    @State private var expandedKeys: Set<String> = []
    @State private var searchText = ""
    // Cached filtered keys to avoid rebuilding the entire dictionary on every keystroke.
    @State private var cachedFilteredKeys: [(key: String, value: Any)] = []

    var body: some View {
        Group {
            if let dict = preview.plistDictionary {
                plistDictView(dict, keyPath: "")
            } else if let array = preview.plistDictionaryArray {
                plistArrayView(array)
            } else {
                Text(String(localized: "Unable to parse property list."))
                    .foregroundStyle(.secondary)
            }
        }
        .searchable(text: $searchText, prompt: String(localized: "Search keys"))
        .onChange(of: searchText) { _, newValue in
            recomputeFilteredKeys(newValue)
        }
        .onAppear {
            recomputeFilteredKeys(searchText)
        }
    }

    private func recomputeFilteredKeys(_ search: String) {
        guard let dict = preview.plistDictionary else {
            cachedFilteredKeys = []
            return
        }
        let sorted = dict.sorted { $0.key < $1.key }
        if search.isEmpty {
            cachedFilteredKeys = sorted.map { ($0.key, $0.value) }
        } else {
            cachedFilteredKeys = sorted
                .filter { $0.key.localizedCaseInsensitiveContains(search) }
                .map { ($0.key, $0.value) }
        }
    }

    private func toggle(_ keyPath: String) {
        if expandedKeys.contains(keyPath) {
            expandedKeys.remove(keyPath)
        } else {
            expandedKeys.insert(keyPath)
        }
    }

    @ViewBuilder
    private func plistDictView(_ dict: [String: Any], keyPath: String) -> some View {
        List {
            ForEach(cachedFilteredKeys, id: \.key) { entry in
                PlistValueRow(
                    key: entry.key,
                    value: entry.value,
                    keyPath: keyPath + entry.key,
                    expandedKeys: expandedKeys,
                    onToggle: { kp in toggle(kp) }
                )
            }
        }
        .listStyle(.insetGrouped)
    }

    private func plistArrayView(_ array: [Any]) -> some View {
        List {
            ForEach(Array(array.enumerated()), id: \.offset) { index, value in
                PlistValueRow(
                    key: "[\(index)]",
                    value: value,
                    keyPath: "[\(index)]",
                    expandedKeys: expandedKeys,
                    onToggle: { kp in toggle(kp) }
                )
            }
        }
        .listStyle(.insetGrouped)
    }

}

extension FilePreview {
    var plistDictionaryArray: [Any]? {
        var format = PropertyListSerialization.PropertyListFormat.binary
        return try? PropertyListSerialization.propertyList(
            from: data, options: [], format: &format
        ) as? [Any]
    }
}

// dictionaries/arrays can be independently expanded/collapsed at any depth.
struct PlistValueRow: View {
    let key: String
    let value: Any
    let keyPath: String
    let expandedKeys: Set<String>
    let onToggle: (String) -> Void
    var depth: Int = 0

    private static let maxDepth = 20
    private static let isoFormatter = ISO8601DateFormatter()

    private var isExpanded: Bool { expandedKeys.contains(keyPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if isExpandable {
                    Button(action: { onToggle(keyPath) }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(key)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer()
                Text(typeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !isExpandable {
                Text(valueDescription)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else if isExpanded {
                expandedContent
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 2)
    }

    private var isExpandable: Bool {
        value is [String: Any] || value is [Any]
    }

    private var typeLabel: LocalizedStringResource {
        if let pv = PlistValue.wrap(value) {
            switch pv {
            case .int: return "Int"
            case .double: return "Double"
            case .bool: return "Bool"
            case .string: return "String"
            case .data: return "Data"
            case .dictionary: return "Dictionary"
            case .array: return "Array"
            case .date: return "Date"
            }
        }
        return "Any"
    }

    private var valueDescription: String {
        if let pv = PlistValue.wrap(value), !pv.isExpandable {
            return pv.displayDescription
        }
        switch value {
        case let v as Bool: return v ? "true" : "false"
        case let v as Int: return String(v)
        case let v as Double: return String(v)
        case let v as String: return "\"\(v)\""
        case let v as Data:
            let hex = v.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
            return "<\(v.count) bytes: \(hex)\(v.count > 32 ? "\u{2026}" : "")>"
        case let v as Date: return Self.isoFormatter.string(from: v)
        default: return String(describing: value)
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        if depth >= Self.maxDepth {
            Text("…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            expandedChildren
        }
    }

    @ViewBuilder
    private var expandedChildren: some View {
        switch value {
        case let dict as [String: Any]:
            ForEach(dict.sorted { $0.key < $1.key }, id: \.key) { k, v in
                PlistValueRow(
                    key: k,
                    value: v,
                    keyPath: keyPath + "." + k,
                    expandedKeys: expandedKeys,
                    onToggle: onToggle,
                    depth: depth + 1
                )
            }
        case let array as [Any]:
            ForEach(Array(array.enumerated()), id: \.offset) { idx, v in
                PlistValueRow(
                    key: "[\(idx)]",
                    value: v,
                    keyPath: keyPath + "[\(idx)]",
                    expandedKeys: expandedKeys,
                    onToggle: onToggle,
                    depth: depth + 1
                )
            }
        default:
            EmptyView()
        }
    }
}
