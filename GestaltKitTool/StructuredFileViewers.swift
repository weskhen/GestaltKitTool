//
//  StructuredFileViewers.swift
//  GestaltKitTool
//
//  Pillar 2: Structured file viewers.
//  Provides rich viewers for JSON, hex dumps, text, and images —
//  all rendered from in-memory Data read via bad_query.
//

import SwiftUI

// MARK: - JSON Viewer

struct JSONViewerView: View {
    let preview: FilePreview
    @State private var searchText = ""

    var body: some View {
        Group {
            if let jsonString = preview.formattedJSON {
                ScrollView {
                    Text(jsonString)
                        .font(.system(.caption, design: .monospaced))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(.systemBackground))
            } else {
                Text(String(localized: "Unable to parse JSON."))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Hex Viewer

struct HexViewerView: View {
    let preview: FilePreview
    @State private var currentPage = 0
    private let pageSize = 4096

    var body: some View {
        VStack(spacing: 0) {
            // Stats bar
            HStack {
                Text(String(format: String(localized: "%d bytes total"), preview.data.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: String(localized: "Page %d / %d"), currentPage + 1, totalPages))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Hex dump
            ScrollView {
                Text(currentPageHex)
                    .font(.system(.caption2, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Page navigation
            HStack {
                Button {
                    if currentPage > 0 { currentPage -= 1 }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentPage == 0)
                .accessibilityLabel(String(localized: "Previous Page"))

                Spacer()

                Button {
                    if currentPage < totalPages - 1 { currentPage += 1 }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(currentPage >= totalPages - 1)
                .accessibilityLabel(String(localized: "Next Page"))
            }
            .padding()
        }
    }

    private var totalPages: Int {
        max(1, (preview.data.count + pageSize - 1) / pageSize)
    }

    private var currentPageHex: String {
        let start = currentPage * pageSize
        let end = min(start + pageSize, preview.data.count)
        guard start < end else { return "" }
        let chunk = preview.data.subdata(in: start..<end)

        var lines: [String] = []
        var offset = start
        for row in chunk.chunked(into: 16) {
            let offsetStr = String(format: "%08x", offset)
            let hexParts = row.map { String(format: "%02x", $0) }
            var hexLine = hexParts.joined(separator: " ")
            if row.count < 16 {
                let padCount = (16 - row.count) * 3 - 1
                hexLine += String(repeating: " ", count: max(0, padCount))
            }
            let ascii = row.map { byte -> String in
                if byte >= 0x20 && byte <= 0x7E {
                    return String(format: "%c", byte)
                } else {
                    return "."
                }
            }.joined()
            lines.append("\(offsetStr)  \(hexLine)  |\(ascii)|")
            offset += 16
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Text Viewer

struct TextViewerView: View {
    let preview: FilePreview

    var body: some View {
        ScrollView {
            Text(preview.textPreview ?? String(localized: "(Unable to decode as text)"))
                .font(.system(.caption, design: .monospaced))
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Image Viewer

struct ImageViewerView: View {
    let preview: FilePreview

    var body: some View {
        VStack {
            if let uiImage = UIImage(data: preview.data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding()
            } else {
                Text(String(localized: "Unable to display image."))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Array Chunk Helper (local, for Data)

extension Data {
    func chunked(into size: Int) -> [Data] {
        stride(from: 0, to: count, by: size).map {
            subdata(in: $0..<Swift.min($0 + size, count))
        }
    }
}
