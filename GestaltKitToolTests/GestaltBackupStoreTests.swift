//
//  GestaltBackupStoreTests.swift
//  GestaltKitToolTests
//

import XCTest
@testable import GestaltKitTool

final class GestaltBackupStoreTests: XCTestCase {
    private var createdBackups: [GestaltBackup] = []

    override func tearDown() {
        // Clean up any backups created during tests.
        for backup in createdBackups {
            try? GestaltBackupStore.delete(backup)
        }
        createdBackups.removeAll()
        super.tearDown()
    }

    func testCreateBackup() throws {
        let data = "test backup content".data(using: .utf8)!
        let backup = try GestaltBackupStore.create(from: data)
        createdBackups.append(backup)
        XCTAssertTrue(backup.url.pathExtension == "plist")
        XCTAssertEqual(backup.byteCount, Int64(data.count))
    }

    func testListBackups() throws {
        let data1 = "backup1".data(using: .utf8)!
        let data2 = "backup2".data(using: .utf8)!
        let b1 = try GestaltBackupStore.create(from: data1)
        createdBackups.append(b1)
        Thread.sleep(forTimeInterval: 0.01)
        let b2 = try GestaltBackupStore.create(from: data2)
        createdBackups.append(b2)

        let backups = try GestaltBackupStore.list()
        XCTAssertGreaterThanOrEqual(backups.count, 2)
        // List should be sorted newest first.
        XCTAssertGreaterThanOrEqual(backups[0].createdAt, backups[1].createdAt)
    }

    func testBackupData() throws {
        let originalData = "restore me".data(using: .utf8)!
        let backup = try GestaltBackupStore.create(from: originalData)
        createdBackups.append(backup)
        let readData = try GestaltBackupStore.data(for: backup)
        XCTAssertEqual(readData, originalData)
    }

    func testDeleteBackup() throws {
        let data = "to be deleted".data(using: .utf8)!
        let backup = try GestaltBackupStore.create(from: data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.url.path))
        try GestaltBackupStore.delete(backup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.url.path))
        // Don't add to createdBackups since it's already deleted.
    }

    func testBackupName() throws {
        let data = "name test".data(using: .utf8)!
        let backup = try GestaltBackupStore.create(from: data)
        createdBackups.append(backup)
        XCTAssertTrue(backup.name.hasPrefix("MobileGestalt_"))
    }
}
