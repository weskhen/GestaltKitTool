//
//  SQLiteParser.swift
//  GestaltKitTool
//
//  In-memory SQLite b-tree parser with interior/overflow support.
//  Parses untrusted binary data from arbitrary .sqlite files.
//

import Foundation

// MARK: - SQLite Parser (in-memory b-tree parser with interior/Overflow support)

struct SQLiteParser {
    private let data: Data
    private let header: SQLiteHeader

    /// Maximum b-tree depth to prevent infinite loops on corrupt files.
    private let maxDepth = 20
    /// Maximum overflow pages to follow per record.
    private let maxOverflowPages = 256

    private let maxPayloadBytes = 10 * 1024 * 1024  // 10 MB
    /// Maximum rows to collect per table (safety cap).
    private let maxRows = 10_000

    init(data: Data) {
        self.data = data
        self.header = SQLiteHeader(data: data)
    }

    // MARK: Header

    private struct SQLiteHeader {
        let pageSize: Int
        let textEncoding: Int
        /// Reserved space at end of each page (usually 0).
        let reservedSpace: Int

        /// Usable page size = pageSize - reservedSpace.
        var usableSize: Int { pageSize - reservedSpace }

        init(data: Data) {
            // Page size at offset 16 (2 bytes, big-endian)
            if data.count >= 18 {
                let ps = Int(data[16]) << 8 | Int(data[17])
                pageSize = ps == 1 ? 65536 : ps
            } else {
                pageSize = 4096
            }
            // Text encoding at offset 56 (4 bytes, big-endian)
            if data.count >= 60 {
                textEncoding = Int(data[56]) << 24 | Int(data[57]) << 16 | Int(data[58]) << 8 | Int(data[59])
            } else {
                textEncoding = 1 // UTF-8
            }
            // Reserved space at offset 20 (1 byte)
            if data.count >= 21 {
                reservedSpace = Int(data[20])
            } else {
                reservedSpace = 0
            }
        }
    }

    // MARK: Table Enumeration (sqlite_master)

    /// Enumerates table names from the schema (sqlite_master) table.
    func parseTables() -> [String] {
        // Page 1 has a 100-byte database header before the b-tree page header.
        let records = collectAllRecords(pageNumber: 1, pageHeaderOffset: 100)

        var tableNames: [String] = []
        for record in records {
            // sqlite_master schema: type, name, tbl_name, rootpage, sql
            if record.count >= 2, let type = record[0], type == "table" {
                if let name = record[1] {
                    tableNames.append(name)
                }
            }
        }
        return tableNames.sorted()
    }

    /// Reads rows from a table by finding its rootpage and traversing the b-tree.
    func parseTable(_ tableName: String) -> (columns: [String], rows: [[String: String]]) {
        // Find the table's rootpage from sqlite_master.
        let schemaRecords = collectAllRecords(pageNumber: 1, pageHeaderOffset: 100)

        var rootpage: Int = 0
        var sql: String = ""
        for record in schemaRecords {
            if record.count >= 5,
               let type = record[0], type == "table",
               let name = record[1], name == tableName {
                rootpage = Int(record[3] ?? "0") ?? 0
                sql = record[4] ?? ""
                break
            }
        }

        guard rootpage > 0 else { return ([], []) }

        // Read the table's b-tree starting from rootpage.
        // For non-page-1 pages, the b-tree header is at offset 0.
        let rowRecords = collectAllRecords(pageNumber: rootpage, pageHeaderOffset: 0)

        // Parse column names from CREATE TABLE SQL.
        let parsedColumns = parseColumnNames(from: sql)
        // actual record data instead of using a fixed 10-column fallback.
        let finalColumns: [String]
        if parsedColumns.isEmpty {
            let maxCols = rowRecords.prefix(20).reduce(0) { max($0, $1.count) }
            finalColumns = generateFallbackColumns(count: max(maxCols, 1))
        } else {
            finalColumns = parsedColumns
        }

        var rows: [[String: String]] = []
        for record in rowRecords {
            var row: [String: String] = [:]
            for (i, col) in finalColumns.enumerated() where i < record.count {
                row[col] = record[i] ?? "NULL"
            }
            rows.append(row)
            if rows.count >= maxRows { break } // safety cap
        }

        return (finalColumns, rows)
    }

    // MARK: B-tree Traversal

    /// Collects all records from a b-tree starting at the given page number.
    /// Handles both leaf pages (0x0D) and interior pages (0x05).
    /// `pageHeaderOffset` is 100 for page 1 (database header), 0 for all other pages.
    private func collectAllRecords(pageNumber: Int, pageHeaderOffset: Int) -> [[String?]] {
        // On 64-bit this is extremely unlikely, but the check is cheap and
        // documents the assumption.
        guard pageNumber > 0, header.pageSize > 0 else { return [] }
        guard pageNumber <= Int.max / header.pageSize else { return [] }
        let pageOffset = (pageNumber - 1) * header.pageSize
        guard pageOffset + pageHeaderOffset < data.count else { return [] }

        let pageEnd = min(pageOffset + header.pageSize, data.count)
        let pageData = data.subdata(in: pageOffset..<pageEnd)

        return collectRecordsFromPage(pageData: pageData, headerOffset: pageHeaderOffset, depth: 0)
    }

    /// Recursively collects records from a page, following interior page child pointers.
    private func collectRecordsFromPage(pageData: Data, headerOffset: Int, depth: Int) -> [[String?]] {
        guard depth < maxDepth else { return [] }
        guard headerOffset < pageData.count else { return [] }

        // Page type at the b-tree header offset.
        let pageType = pageData[headerOffset]

        switch pageType {
        case 0x0D: // Table leaf page
            return parseLeafPage(pageData: pageData, headerOffset: headerOffset)

        case 0x05: // Table interior page — follow child pointers
            return parseInteriorPage(pageData: pageData, headerOffset: headerOffset, depth: depth)

        default:
            // Not a table b-tree page (could be index page 0x0A/0x02, or not a b-tree at all).
            return []
        }
    }

    /// Parses a table interior page (type 0x05), following all child page pointers.
    private func parseInteriorPage(pageData: Data, headerOffset: Int, depth: Int) -> [[String?]] {
        // Interior page header is 12 bytes (vs 8 for leaf).
        guard headerOffset + 12 <= pageData.count else { return [] }

        // Cell count at headerOffset + 3 (2 bytes big-endian).
        let cellCount = Int(pageData[headerOffset + 3]) << 8 | Int(pageData[headerOffset + 4])

        // Right-most pointer at headerOffset + 8 (4 bytes big-endian).
        let rightMostPointer = readUInt32(pageData, at: headerOffset + 8)

        var allRecords: [[String?]] = []

        // Cell pointer array starts at headerOffset + 12 for interior pages.
        let cellPointerStart = headerOffset + 12

        for i in 0..<cellCount {
            let pointerOffset = cellPointerStart + i * 2
            guard pointerOffset + 2 <= pageData.count else { continue }

            // Cell offset (2 bytes, big-endian) — relative to the start of the page.
            let cellOffset = Int(pageData[pointerOffset]) << 8 | Int(pageData[pointerOffset + 1])
            guard cellOffset + 4 <= pageData.count else { continue }

            // Left child page number (4 bytes at the cell offset).
            let childPage = readUInt32(pageData, at: cellOffset)

            // Recurse into the child page.
            let childRecords = collectAllRecords(pageNumber: Int(childPage), pageHeaderOffset: 0)
            allRecords.append(contentsOf: childRecords)
        }

        // Follow the right-most pointer.
        if rightMostPointer > 0 {
            let rightRecords = collectAllRecords(pageNumber: Int(rightMostPointer), pageHeaderOffset: 0)
            allRecords.append(contentsOf: rightRecords)
        }

        return allRecords
    }

    /// Parses a table leaf page (type 0x0D).
    private func parseLeafPage(pageData: Data, headerOffset: Int) -> [[String?]] {
        // Leaf page header is 8 bytes.
        guard headerOffset + 8 <= pageData.count else { return [] }

        let pageType = pageData[headerOffset]
        guard pageType == 0x0D else { return [] }

        // Cell count at headerOffset + 3 (2 bytes big-endian).
        let cellCount = Int(pageData[headerOffset + 3]) << 8 | Int(pageData[headerOffset + 4])

        // Cell pointer array starts at headerOffset + 8.
        let cellPointerStart = headerOffset + 8
        // as the interior page guard above for clarity and correctness.
        guard cellPointerStart + cellCount * 2 <= pageData.count else { return [] }

        var records: [[String?]] = []

        for i in 0..<cellCount {
            let pointerOffset = cellPointerStart + i * 2
            guard pointerOffset + 2 <= pageData.count else { continue }
            // Cell offset is relative to the start of the page (not the header).
            let cellOffset = Int(pageData[pointerOffset]) << 8 | Int(pageData[pointerOffset + 1])
            guard cellOffset < pageData.count else { continue }

            if let record = parseCell(at: cellOffset, in: pageData) {
                records.append(record)
            }
        }

        return records
    }

    // MARK: Cell Parsing

    /// Parses a single cell in a table leaf page.
    private func parseCell(at offset: Int, in pageData: Data) -> [String?]? {
        var pos = offset
        guard pos < pageData.count else { return nil }

        // Payload length (varint) — total payload size including overflow.
        let (payloadLen, lenBytes) = readVarint(at: pos, in: pageData)
        pos += lenBytes

        // Row ID (varint).
        let (_, rowIdBytes) = readVarint(at: pos, in: pageData)
        pos += rowIdBytes

        let totalPayloadLen = Int(payloadLen)

        guard totalPayloadLen <= maxPayloadBytes else { return nil }

        // Compute local payload size vs overflow.
        // Per SQLite spec: U = usableSize, X = U - 35 (max local for leaf).
        // If totalPayloadLen <= X, all data is local.
        // Otherwise local = M + ((totalPayloadLen - M) % (U - 4)), where M = ((U - 12) * 32 / 255) - 23.
        let U = header.usableSize
        let X = U - 35
        let localPayloadLen: Int
        if totalPayloadLen <= X {
            localPayloadLen = totalPayloadLen
        } else {
            let M = ((U - 12) * 32 / 255) - 23
            let K = M + ((totalPayloadLen - M) % (U - 4))
            localPayloadLen = K <= X ? K : M
        }

        guard pos + localPayloadLen <= pageData.count else { return nil }

        // Read local payload.
        // long overflow chains.
        var payload = Data()
        payload.reserveCapacity(totalPayloadLen)
        payload.append(pageData.subdata(in: pos..<pos + localPayloadLen))

        // If there's overflow, follow the overflow page chain.
        if totalPayloadLen > localPayloadLen {
            // The 4 bytes immediately after the local payload contain the first overflow page number.
            let overflowStart = pos + localPayloadLen
            guard overflowStart + 4 <= pageData.count else { return nil }
            var overflowPage = Int(readUInt32(pageData, at: overflowStart))
            var remaining = totalPayloadLen - localPayloadLen
            var pagesFollowed = 0

            while overflowPage > 0 && remaining > 0 && pagesFollowed < maxOverflowPages {
                guard overflowPage <= Int.max / header.pageSize else { break }
                let overflowOffset = (overflowPage - 1) * header.pageSize
                guard overflowOffset + 4 < data.count else { break }

                // First 4 bytes of overflow page = next overflow page number.
                let nextOverflow = Int(readUInt32(data, at: overflowOffset))

                // Remaining data on this overflow page (up to usableSize - 4).
                let chunkSize = min(remaining, header.usableSize - 4)
                let chunkStart = overflowOffset + 4
                guard chunkStart + chunkSize <= data.count else { break }

                payload.append(data.subdata(in: chunkStart..<chunkStart + chunkSize))
                remaining -= chunkSize
                overflowPage = nextOverflow
                pagesFollowed += 1
            }
        }

        return parseRecord(payload)
    }

    /// Parses a record (header + values) from the payload.
    private func parseRecord(_ payload: Data) -> [String?]? {
        guard payload.count > 0 else { return nil }

        // Header length (varint).
        let (headerLen, headerLenBytes) = readVarint(at: 0, in: payload)
        guard Int(headerLen) <= payload.count else { return nil }

        // Parse serial types from header.
        var serialTypes: [Int] = []
        var pos = headerLenBytes
        while pos < Int(headerLen) {
            let (serialType, bytes) = readVarint(at: pos, in: payload)
            serialTypes.append(Int(serialType))
            pos += bytes
        }

        // Parse values from body.
        var values: [String?] = []
        pos = Int(headerLen)

        for serialType in serialTypes {
            let (value, size) = readValue(serialType: serialType, at: pos, in: payload)
            values.append(value)
            pos += size
        }

        return values
    }

    // MARK: Low-level Readers

    /// Reads a 4-byte big-endian UInt32 from data at the given offset.
    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) << 24 |
               UInt32(data[offset + 1]) << 16 |
               UInt32(data[offset + 2]) << 8 |
               UInt32(data[offset + 3])
    }

    /// Reads a varint (variable-length integer) from data.
    private func readVarint(at offset: Int, in data: Data) -> (UInt64, Int) {
        var result: UInt64 = 0
        var bytes = 0

        for i in 0..<9 {
            guard offset + i < data.count else { break }
            let byte = data[offset + i]
            bytes += 1
            if i < 8 {
                result = (result << 7) | UInt64(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            } else {
                result = (result << 8) | UInt64(byte)
            }
        }

        return (result, bytes)
    }

    /// Reads a value based on its serial type.
    private func readValue(serialType: Int, at offset: Int, in data: Data) -> (String?, Int) {
        switch serialType {
        case 0:
            return (nil, 0) // NULL
        case 1:
            guard offset < data.count else { return ("NULL", 0) }
            let val = Int(Int8(bitPattern: data[offset]))
            return (String(val), 1)
        case 2:
            guard offset + 1 < data.count else { return ("NULL", 0) }
            let raw = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
            let val = Int(Int16(bitPattern: raw))
            return (String(val), 2)
        case 3:
            guard offset + 2 < data.count else { return ("NULL", 0) }
            let raw = (Int(data[offset]) << 16) | (Int(data[offset + 1]) << 8) | Int(data[offset + 2])
            // Sign-extend from 24 bits.
            let val = raw >= 0x800000 ? raw - 0x1000000 : raw
            return (String(val), 3)
        case 4:
            guard offset + 3 < data.count else { return ("NULL", 0) }
            let raw = (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
            let val = Int(Int32(bitPattern: raw))
            return (String(val), 4)
        case 5:
            guard offset + 5 < data.count else { return ("NULL", 0) }
            var raw: UInt64 = 0
            for i in 0..<6 {
                raw = (raw << 8) | UInt64(data[offset + i])
            }
            // Sign-extend from 48 bits.
            let signBit: UInt64 = 1 << 47
            let val = raw >= signBit ? Int64(raw) - Int64(1 << 48) : Int64(raw)
            return (String(val), 6)
        case 6:
            guard offset + 7 < data.count else { return ("NULL", 0) }
            var raw: UInt64 = 0
            for i in 0..<8 {
                raw = (raw << 8) | UInt64(data[offset + i])
            }
            let val = Int64(bitPattern: raw)
            return (String(val), 8)
        case 7:
            // 64-bit float (IEEE 754).
            guard offset + 7 < data.count else { return ("NULL", 0) }
            var raw: UInt64 = 0
            for i in 0..<8 {
                raw = (raw << 8) | UInt64(data[offset + i])
            }
            let double = Double(bitPattern: raw)
            return (String(double), 8)
        case 8:
            return ("0", 0) // integer 0
        case 9:
            return ("1", 0) // integer 1
        case 10, 11:
            return ("NULL", 0) // reserved
        default:
            // serialType >= 12: BLOB or text.
            let length = (serialType - 12) / 2
            guard offset + length <= data.count else { return ("NULL", 0) }
            if serialType % 2 == 0 {
                // BLOB — show as hex (truncated for display).
                let blob = data.subdata(in: offset..<offset + length)
                let hex = blob.prefix(256).map { String(format: "%02x", $0) }.joined(separator: " ")
                return (hex.isEmpty ? "NULL" : hex + (blob.count > 256 ? "\u{2026}" : ""), length)
            } else {
                // TEXT — truncate very long strings for display.
                let textData = data.subdata(in: offset..<offset + length)
                let text = String(data: textData, encoding: .utf8)
                if let text {
                    // Truncate display to 2000 chars.
                    if text.count > 2000 {
                        return (String(text.prefix(2000)) + "\u{2026}", length)
                    }
                    return (text, length)
                }
                return ("(binary)", length)
            }
        }
    }

    // MARK: Column Name Parsing

    /// Parses column names from a CREATE TABLE SQL statement.
    private func parseColumnNames(from sql: String) -> [String] {
        // Find the parenthesized column list.
        guard let openParen = sql.firstIndex(of: "("),
              let closeParen = sql.lastIndex(of: ")") else { return [] }
        let columnsStr = String(sql[sql.index(after: openParen)..<closeParen])

        var columns: [String] = []
        var depth = 0
        var current = ""
        var inQuote: Character? = nil

        for ch in columnsStr {
            if let q = inQuote {
                current.append(ch)
                if ch == q { inQuote = nil }
                continue
            }

            switch ch {
            case "`", "\"", "'":
                inQuote = ch
                current.append(ch)
            case "(":
                depth += 1
                current.append(ch)
            case ")":
                depth -= 1
                current.append(ch)
            case ",":
                if depth == 0 {
                    // End of a column definition.
                    if let name = extractColumnName(from: current) {
                        columns.append(name)
                    }
                    current = ""
                } else {
                    current.append(ch)
                }
            default:
                current.append(ch)
            }
        }

        // Don't forget the last column.
        if !current.isEmpty {
            if let name = extractColumnName(from: current) {
                columns.append(name)
            }
        }

        return columns
    }

    /// Extracts the column name from a single column definition string.
    /// Skips table-level constraint keywords.
    private func extractColumnName(from def: String) -> String? {
        let trimmed = def.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Skip table-level constraints.
        let upper = trimmed.uppercased()
        let constraintKeywords: Set<String> = [
            "PRIMARY", "UNIQUE", "CHECK", "FOREIGN", "CONSTRAINT", "KEY"
        ]
        let firstWord = upper.split(separator: " ").first.map(String.init) ?? ""
        if constraintKeywords.contains(firstWord) {
            return nil
        }

        // Handle quoted identifiers.
        // optional binding for defense-in-depth in untrusted parser.
        if let first = trimmed.first, first == "`" || first == "\"" {
            if let endQuote = trimmed.dropFirst().firstIndex(of: first) {
                return String(trimmed[trimmed.index(after: trimmed.startIndex)..<endQuote])
            }
        }

        // Extract the first word (the column name).
        if let firstSpace = trimmed.firstIndex(of: " ") {
            return String(trimmed[..<firstSpace])
        }

        return trimmed
    }

    /// Generates fallback column names (col0, col1, ...) when SQL parsing fails.
    private func generateFallbackColumns(count: Int) -> [String] {
        (0..<count).map { "col\($0)" }
    }
}
