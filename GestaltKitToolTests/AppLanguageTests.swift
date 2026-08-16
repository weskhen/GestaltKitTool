//
//  AppLanguageTests.swift
//  GestaltKitToolTests
//

import XCTest
@testable import GestaltKitTool

final class AppLanguageTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Clean any stored language before each test.
        UserDefaults.standard.removeObject(forKey: AppLanguage.storageKey)
    }

    func testRawValues() {
        XCTAssertEqual(AppLanguage.system.rawValue, "system")
        XCTAssertEqual(AppLanguage.zhHans.rawValue, "zhHans")
        XCTAssertEqual(AppLanguage.en.rawValue, "en")
    }

    func testAppleLanguagesValueSystem() {
        XCTAssertNil(AppLanguage.system.appleLanguagesValue)
    }

    func testAppleLanguagesValueZhHans() {
        XCTAssertEqual(AppLanguage.zhHans.appleLanguagesValue, ["zh-Hans"])
    }

    func testAppleLanguagesValueEn() {
        XCTAssertEqual(AppLanguage.en.appleLanguagesValue, ["en"])
    }

    func testCurrentDefaultsToSystem() {
        UserDefaults.standard.removeObject(forKey: AppLanguage.storageKey)
        XCTAssertEqual(AppLanguage.current, .system)
    }

    func testCurrentReadsStoredValue() {
        UserDefaults.standard.set("zhHans", forKey: AppLanguage.storageKey)
        XCTAssertEqual(AppLanguage.current, .zhHans)
    }

    func testCurrentFallsBackOnInvalidValue() {
        UserDefaults.standard.set("invalid", forKey: AppLanguage.storageKey)
        XCTAssertEqual(AppLanguage.current, .system)
    }

    func testAllCasesCount() {
        XCTAssertEqual(AppLanguage.allCases.count, 3)
    }

    func testApplyToUserDefaultsSystem() {
        LanguageManager.applyToUserDefaults(.system)
        XCTAssertNil(UserDefaults.standard.array(forKey: AppLanguage.appleLanguagesKey))
    }

    func testApplyToUserDefaultsZhHans() {
        LanguageManager.applyToUserDefaults(.zhHans)
        XCTAssertEqual(UserDefaults.standard.array(forKey: AppLanguage.appleLanguagesKey) as? [String], ["zh-Hans"])
        UserDefaults.standard.removeObject(forKey: AppLanguage.appleLanguagesKey)
    }

    func testApplyToUserDefaultsEn() {
        LanguageManager.applyToUserDefaults(.en)
        XCTAssertEqual(UserDefaults.standard.array(forKey: AppLanguage.appleLanguagesKey) as? [String], ["en"])
        UserDefaults.standard.removeObject(forKey: AppLanguage.appleLanguagesKey)
    }
}
