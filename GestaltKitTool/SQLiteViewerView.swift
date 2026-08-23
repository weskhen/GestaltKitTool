//
//  SQLiteViewerView.swift
//  GestaltKitTool
//
//  Provides a SwiftUI view for browsing SQLite databases parsed
//  by SQLiteParser (in-memory, no file system access needed).
//

import SwiftUI

// MARK: - SQLite Viewer

struct SQLiteViewerView: View {
    let preview: FilePreview
    @State private var tables: [String] = []
    @State private var selectedTable: String?
    @State private var rows: [[String: String]] = []
    @State private var columns: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let pageSize = 100
    @State private var displayedRowCount = 100

    // previously viewed table doesn't re-parse the entire database.
    private struct CachedTable {
        let columns: [String]
        let rows: [[String: String]]
        var lastAccess: Date
    }
    @State private var cachedTables: [String: CachedTable] = [:]
    private let maxCachedTables = 3

    private func clearTableCache() {
        cachedTables.removeAll()
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                errorView(errorMessage)
            } else if isLoading && tables.isEmpty {
                ProgressView(String(localized: "Reading database…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tables.isEmpty {
                errorView(String(localized: "No tables found or file is not a valid SQLite database."))
            } else {
                // Table selector
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tables, id: \.self) { table in
                            Button(table) {
                                loadTable(table)
                            }
                            .buttonStyle(.bordered)
                            .tint(selectedTable == table ? .accentColor : .secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .background(Color(.secondarySystemBackground))

                // Data table
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !rows.isEmpty {
                    tableDataView
                } else {
                    Text(String(localized: "Select a table to view its contents."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            parseDatabase()
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryPressureMonitor.didReceiveWarning)) { _ in
            clearTableCache()
        }
    }

    private var tableDataView: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    ForEach(columns, id: \.self) { col in
                        Text(col)
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .frame(minWidth: 100, alignment: .leading)
                            .padding(8)
                            .background(Color.accentColor.opacity(0.8))
                    }
                }
                // Data rows — only up to displayedRowCount
                let visibleRows = Array(rows.prefix(displayedRowCount))
                ForEach(Array(visibleRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(columns, id: \.self) { col in
                            Text(row[col] ?? "NULL")
                                .font(.caption)
                                .lineLimit(2)
                                .frame(minWidth: 100, alignment: .leading)
                                .padding(8)
                                .background(Color(.systemBackground))
                        }
                    }
                    Divider()
                }

                // Load More button
                if displayedRowCount < rows.count {
                    Button {
                        displayedRowCount = min(displayedRowCount + pageSize, rows.count)
                    } label: {
                        Text(String(format: String(localized: "Load More (%d remaining)"), max(0, rows.count - displayedRowCount)))
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                    }
                    .buttonStyle(.bordered)
                    .padding(8)
                }

                Text(String(format: String(localized: "Showing %d of %d rows"), visibleRows.count, rows.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(msg)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: SQLite Parsing

    private func parseDatabase() {
        isLoading = true
        // any CoW data race on preview.data's underlying buffer.
        let data = Data(preview.data)

        Task.detached(priority: .userInitiated) {
            let parser = SQLiteParser(data: data)
            let parsedTables = parser.parseTables()
            let firstTable = parsedTables.first

            DispatchQueue.main.async {
                tables = parsedTables
                isLoading = false
                if let firstTable {
                    loadTable(firstTable)
                }
            }
        }
    }

    private func loadTable(_ table: String) {
        selectedTable = table
        isLoading = true
        displayedRowCount = pageSize // reset pagination on table switch

        if let cached = cachedTables[table] {
            columns = cached.columns
            rows = cached.rows
            isLoading = false
            cachedTables[table]?.lastAccess = Date()
            return
        }

        let data = Data(preview.data)

        Task.detached(priority: .userInitiated) {
            let parser = SQLiteParser(data: data)
            let (cols, dataRows) = parser.parseTable(table)

            DispatchQueue.main.async {
                columns = cols
                rows = dataRows
                while cachedTables.count >= maxCachedTables {
                    if let oldestKey = cachedTables.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
                        cachedTables.removeValue(forKey: oldestKey)
                    } else { break }
                }
                cachedTables[table] = CachedTable(columns: cols, rows: dataRows, lastAccess: Date())
                isLoading = false
            }
        }
    }
}
