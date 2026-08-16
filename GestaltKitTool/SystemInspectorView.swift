//
//  SystemInspectorView.swift
//  GestaltKitTool
//
//  Sensitive system file inspector.
//  Displays predefined targets for system files that can be
//  read via bad_query path traversal, and shows parsed contents.
//

import Combine
import SwiftUI

struct SystemInspectorView: View {
    @StateObject private var model = SystemInspectorModel()

    var body: some View {
        NavigationStack {
            List {
                // Warning banner
                Section {
                    Label {
                        Text("These files contain sensitive system data. Reading them demonstrates the full impact of bad_query sandbox escape.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                // Target categories
                ForEach(SystemInspectorModel.groupedTargets, id: \.category) { group in
                    Section {
                        ForEach(group.targets) { target in
                            SystemFileRow(
                                target: target,
                                isLoading: model.loadingTargetId == target.id,
                                result: model.results.first { $0.target.id == target.id },
                                onTap: { model.readTarget(target) }
                            )
                        }
                    } header: {
                        Label(group.category.localizedTitle, systemImage: group.category.icon)
                    }
                }

                // Results section
                if !model.results.isEmpty {
                    Section {
                        ForEach(model.results) { result in
                            SystemFileResultRow(result: result)
                        }
                    } header: {
                        HStack {
                            Text("Results")
                            Spacer()
                            Button("Clear All") {
                                model.results.removeAll()
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Inspector")
            .navigationBarTitleDisplayMode(.large)
            .alert(String(localized: "Error"), isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }
}

// MARK: - System File Row

private struct SystemFileRow: View {
    let target: SystemFileTarget
    let isLoading: Bool
    let result: SystemFileResult?
    let onTap: () -> Void

    @State private var showsResultSheet = false

    var body: some View {
        Button {
            if result != nil {
                showsResultSheet = true
            } else {
                onTap()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: target.riskLevel.icon)
                    .foregroundStyle(riskColor)
                    .font(.body)

                VStack(alignment: .leading, spacing: 3) {
                    Text(target.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(target.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Text(target.riskLevel.label)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(riskColor.opacity(0.15))
                            .foregroundStyle(riskColor)
                            .clipShape(Capsule())

                        Text(target.path)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    // Show result summary or error inline
                    if let result {
                        HStack(spacing: 4) {
                            Image(systemName: result.isSuccess ? "checkmark.circle" : "xmark.circle")
                                .font(.caption2)
                            Text(result.summary)
                                .font(.caption2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .foregroundStyle(result.isSuccess ? .green : .red)
                    }
                }

                Spacer()

                if isLoading {
                    ProgressView()
                } else if result != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showsResultSheet) {
            if let result {
                SystemFileResultSheet(result: result)
            }
        }
    }

    private var riskColor: Color {
        switch target.riskLevel {
        case .low: .green
        case .medium: .yellow
        case .high: .orange
        case .critical: .red
        }
    }
}

// MARK: - System File Result Row

private struct SystemFileResultRow: View {
    let result: SystemFileResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(result.target.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(result.readDate, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(result.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - System File Result Sheet

private struct SystemFileResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    let result: SystemFileResult
    @State private var displayMode: DisplayMode = .parsed
    @State private var exportedFileURL: URL?

    enum DisplayMode: String, CaseIterable {
        case parsed, raw, hex
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    infoHeader
                    Divider()
                    contentDisplay
                }
                .padding()
            }
            .navigationTitle(result.target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        if result.isSuccess, let exportedFileURL {
                            ShareLink(item: exportedFileURL) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel(String(localized: "Export"))
                        }
                        Picker("Mode", selection: $displayMode) {
                            ForEach(DisplayMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue.capitalized).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }
                }
            }
            .task {
                guard result.isSuccess, exportedFileURL == nil else { return }
                let ext = (result.target.path as NSString).pathExtension.isEmpty
                    ? "txt" : (result.target.path as NSString).pathExtension
                let fileName = "\(result.target.title).\(ext)"
                let url = ExportFileManager.makeExportURL(fileName: fileName, data: result.data)
                exportedFileURL = url
            }
        }
    }

    private var infoHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Path") {
                Text(result.target.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Size") {
                Text(ByteCountFormatter.string(fromByteCount: result.fileSize, countStyle: .file))
            }
            LabeledContent("Read At") {
                Text(result.readDate, format: .dateTime)
            }
            LabeledContent("Risk") {
                HStack(spacing: 4) {
                    Image(systemName: result.target.riskLevel.icon)
                    Text(result.target.riskLevel.label)
                }
                .foregroundStyle(riskColor)
            }
            LabeledContent("Status") {
                HStack(spacing: 4) {
                    Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    Text(result.isSuccess ? String(localized: "Success") : String(localized: "Failed"))
                }
                .foregroundStyle(result.isSuccess ? .green : .red)
            }

            if !result.isSuccess, let msg = result.errorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Error Details"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private var contentDisplay: some View {
        switch displayMode {
        case .parsed:
            parsedDisplay
        case .raw:
            rawDisplay
        case .hex:
            hexDisplay
        }
    }

    @ViewBuilder
    private var parsedDisplay: some View {
        switch result.parsedContent {
        case .plist(let dict):
            PlistDisplayView(dict: dict)
        case .text(let text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .hex(let hex):
            Text(hex)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .json(let json):
            if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .binary:
            hexDisplay
        case .error(let msg):
            Text(msg)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var rawDisplay: some View {
        if let text = String(data: result.data, encoding: .utf8) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            hexDisplay
        }
    }

    private var hexDisplay: some View {
        let hex = result.data.prefix(8192).map { String(format: "%02x", $0) }
            .chunked(into: 16).map { $0.joined(separator: " ") }
            .joined(separator: "\n")
        return Text(hex)
            .font(.system(.caption2, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var riskColor: Color {
        switch result.target.riskLevel {
        case .low: .green
        case .medium: .yellow
        case .high: .orange
        case .critical: .red
        }
    }
}

// MARK: - Plist Display View

struct PlistDisplayView: View {
    let dict: [String: Any]
    /// Maximum nesting depth for the recursive tree. Beyond this,
    /// values are shown as a summary string instead of expanding.
    static let maxDepth = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(dict.keys.sorted(), id: \.self) { key in
                PlistKeyRow(
                    key: key,
                    value: dict[key] ?? "",
                    depth: 0
                )
            }
        }
    }
}

struct PlistKeyRow: View {
    let key: String
    let value: Any
    let depth: Int
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if isDict || isArray {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Text(key)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)

                Spacer()

                Text(valueSummary)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, CGFloat(depth) * 16)

            if isExpanded {
                expandedContent
            }
        }
    }

    private var isDict: Bool { value is [String: Any] }
    private var isArray: Bool { value is [Any] }

    private var valueSummary: String {
        switch value {
        case let s as String:
            return s.isEmpty ? "\"\"" : "\"\(s.prefix(50))\""
        case let n as NSNumber:
            return n.stringValue
        case let d as Data:
            return String(format: "<%d bytes>", d.count)
        case let dict as [String: Any]:
            return "{\(dict.count) keys}"
        case let arr as [Any]:
            return "[\(arr.count) items]"
        default:
            return String(describing: value)
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        if depth >= PlistDisplayView.maxDepth {
            // Depth guard: show a summary instead of recursing further
            // to prevent stack overflow and excessive view creation.
            Text("(…)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, CGFloat(depth + 1) * 16)
        } else if let dict = value as? [String: Any] {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(dict.keys.sorted(), id: \.self) { k in
                    PlistKeyRow(
                        key: k,
                        value: dict[k] ?? "",
                        depth: depth + 1
                    )
                }
            }
        } else if let arr = value as? [Any] {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(arr.indices, id: \.self) { i in
                    PlistKeyRow(
                        key: "[\(i)]",
                        value: arr[i],
                        depth: depth + 1
                    )
                }
            }
        }
    }
}
