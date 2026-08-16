//
//  FilePreviewTests.swift
//  GestaltKitToolTests
//

import XCTest
@testable import GestaltKitTool

final class FilePreviewTests: XCTestCase {
    // BQFileEntry has readonly properties set via a private class extension.
    // In Swift, BQFileEntry() creates an instance with empty/zero defaults.
    // entry.name will be "" so detectedType falls through to magic-byte detection.
    private func makeEntry() -> BQFileEntry {
        BQFileEntry()
    }

    // MARK: - Text detection (via UTF-8 fallback)

    func testDetectedTypeTextByContent() {
        let entry = makeEntry()
        let data = "Hello World".data(using: .utf8)!
        let preview = FilePreview(entry: entry, data: data)
        XCTAssertEqual(preview.detectedType, .text)
    }

    func testTextPreviewContent() {
        let entry = makeEntry()
        let content = "Line 1\nLine 2"
        let data = content.data(using: .utf8)!
        let preview = FilePreview(entry: entry, data: data)
        XCTAssertEqual(preview.textPreview, content)
    }

    // MARK: - Image detection (magic bytes)

    func testDetectedTypePNGByMagic() {
        let entry = makeEntry()
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let preview = FilePreview(entry: entry, data: data)
        XCTAssertEqual(preview.detectedType, .image)
    }

    func testDetectedTypeJPEGByMagic() {
        let entry = makeEntry()
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let preview = FilePreview(entry: entry, data: data)
        XCTAssertEqual(preview.detectedType, .image)
    }

    // MARK: - Binary detection

    func testDetectedTypeBinary() {
        let entry = makeEntry()
        let data = Data([0x00, 0x01, 0x02, 0x03])
        let preview = FilePreview(entry: entry, data: data)
        XCTAssertEqual(preview.detectedType, .binary)
    }

    // MARK: - Hex dump

    func testHexDumpFormat() {
        let entry = makeEntry()
        let data = Data([0x41, 0x42, 0x43])
        let preview = FilePreview(entry: entry, data: data)
        let hex = preview.hexPreview
        XCTAssertTrue(hex.contains("00000000"), "Hex dump should contain offset column")
        XCTAssertTrue(hex.contains("41 42 43"), "Hex dump should contain hex bytes")
        XCTAssertTrue(hex.contains("|ABC|"), "Hex dump should contain ASCII sidebar")
    }

    func testHexDumpNonPrintableAsDot() {
        let entry = makeEntry()
        let data = Data([0x00, 0x01, 0x02])
        let preview = FilePreview(entry: entry, data: data)
        let hex = preview.hexPreview
        XCTAssertTrue(hex.contains("|...|"), "Non-printable bytes should be dots")
    }

    func testHexDumpEmptyData() {
        let entry = makeEntry()
        let data = Data()
        let preview = FilePreview(entry: entry, data: data)
        let hex = preview.hexPreview
        XCTAssertTrue(hex.isEmpty, "Empty data should produce empty hex dump")
    }

    func testHexDumpFullRow() {
        let entry = makeEntry()
        let data = Data((0..<16).map { _ in UInt8(0x41) }) // 16 'A's
        let preview = FilePreview(entry: entry, data: data)
        let hex = preview.hexPreview
        XCTAssertTrue(hex.contains("|AAAAAAAAAAAAAAAA|"), "Full row should have 16 ASCII chars")
    }

    // MARK: - Plist detection (via property list parsing, not extension)

    func testPlistDictionaryFromBinary() {
        let entry = makeEntry()
        let dict: [String: Any] = ["name": "GestaltKitTool", "version": 1]
        let data = PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)!
        // entry.name is "" so detectedType won't be .plist.
        // plistDictionary checks detectedType == .plist, so this returns nil.
        let preview = FilePreview(entry: entry, data: data)
        // Since extension is "", the binary plist magic "bplist" is valid UTF-8 text?
        // Actually bplist00 starts with 0x62 0x70 0x6C 0x69 → "bpli" which is ASCII text.
        // So detectedType will be .text, not .plist.
        // This test verifies the fallback behavior.
        XCTAssertNotEqual(preview.detectedType, .plist)
    }

    // MARK: - Equatable

    func testFilePreviewEquatableSelf() {
        let entry = makeEntry()
        let data = Data([0x00])
        let preview = FilePreview(entry: entry, data: data)
        XCTAssertTrue(preview == preview)
    }

    func testFilePreviewNotEqualToNewInstance() {
        let entry = makeEntry()
        let data = Data([0x00])
        let preview1 = FilePreview(entry: entry, data: data)
        let preview2 = FilePreview(entry: entry, data: data)
        // Each FilePreview gets a unique UUID, so they are never equal.
        XCTAssertFalse(preview1 == preview2)
    }
}
