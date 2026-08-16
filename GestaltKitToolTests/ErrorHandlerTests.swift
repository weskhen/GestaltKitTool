//
//  ErrorHandlerTests.swift
//  GestaltKitToolTests
//

import XCTest
@testable import GestaltKitTool

final class ErrorHandlerTests: XCTestCase {
    // MARK: - BadQueryFileAccess domain errors

    func testAbsolutePathRequired() {
        let error = NSError(
            domain: "com.wesk.vtool.badqueryfile", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "An absolute path is required."]
        )
        let msg = ErrorHandler.friendlyMessage(for: error)
        XCTAssertTrue(msg.contains("absolute"), "Expected 'absolute' in message, got: \(msg)")
    }

    func testSandboxDenied() {
        let error = NSError(
            domain: "com.wesk.vtool.badqueryfile", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "bad_query failed"]
        )
        let msg = ErrorHandler.friendlyMessage(for: error)
        XCTAssertTrue(msg.contains("Sandbox"), "Expected 'Sandbox' in message, got: \(msg)")
    }

    func testFileReadFailure() {
        let error = NSError(
            domain: "com.wesk.vtool.badqueryfile", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "read failed"]
        )
        let msg = ErrorHandler.friendlyMessage(for: error)
        XCTAssertTrue(msg.contains("read"), "Expected 'read' in message, got: \(msg)")
    }

    func testStatFailure() {
        let error = NSError(
            domain: "com.wesk.vtool.badqueryfile", code: 5,
            userInfo: [NSLocalizedDescriptionKey: "stat failed"]
        )
        let msg = ErrorHandler.friendlyMessage(for: error)
        XCTAssertTrue(msg.contains("metadata"), "Expected 'metadata' in message, got: \(msg)")
    }

    // MARK: - GestaltAccess domain errors

    func testUnsupportedOS() {
        let error = NSError(
            domain: "com.wesk.vtool.access", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "unsupported OS"]
        )
        let msg = ErrorHandler.friendlyMessage(for: error)
        XCTAssertTrue(msg.contains("iOS version"), "Expected 'iOS version' in message, got: \(msg)")
    }

    func testBadQueryUnavailable() {
        let error = NSError(
            domain: "com.wesk.vtool.access", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "unavailable"]
        )
        let msg = ErrorHandler.friendlyMessage(for: error)
        XCTAssertTrue(msg.contains("bad_query"), "Expected 'bad_query' in message, got: \(msg)")
    }

    // MARK: - POSIX error mapping

    func testENOENT() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: ENOENT)
        let error = NSError(
            domain: NSCocoaErrorDomain, code: 4,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        let msg = ErrorHandler.friendlyMessage(for: error)
        XCTAssertTrue(msg.contains("does not exist"), "Expected 'does not exist' in message, got: \(msg)")
    }

    func testEACCES() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: EACCES)
        let error = NSError(
            domain: NSCocoaErrorDomain, code: 4,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        let msg = ErrorHandler.friendlyMessage(for: error)
        XCTAssertTrue(msg.contains("Permission"), "Expected 'Permission' in message, got: \(msg)")
    }

    // MARK: - Fallback

    func testUnknownErrorFallback() {
        let error = NSError(domain: "com.unknown.domain", code: 999)
        let msg = ErrorHandler.friendlyMessage(for: error)
        XCTAssertFalse(msg.isEmpty, "Fallback message should not be empty")
    }

    func testStatusLabelSuccess() {
        XCTAssertEqual(ErrorHandler.statusLabel(success: true), "Success")
    }

    func testStatusLabelFailure() {
        XCTAssertEqual(ErrorHandler.statusLabel(success: false), "Failed")
    }
}
