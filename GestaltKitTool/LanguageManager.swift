//
//  LanguageManager.swift
//  GestaltKitTool
//
//  Manages an in-app language override (Chinese / English / Follow System).
//  The preference is written to UserDefaults "AppleLanguages" so that
//  String(localized:) resolves against the chosen language on next launch.
//

import Combine
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    /// Follow the system-preferred language (default).
    case system
    /// Force Simplified Chinese.
    case zhHans
    /// Force English.
    case en

    var id: String { rawValue }

    /// The value written to UserDefaults "AppleLanguages".
    /// `nil` means "remove the override and let the system decide".
    var appleLanguagesValue: [String]? {
        switch self {
        case .system: nil
        case .zhHans: ["zh-Hans"]
        case .en: ["en"]
        }
    }

    var label: String {
        switch self {
        case .system: String(localized: "Follow System")
        case .zhHans: "简体中文"
        case .en: "English"
        }
    }

    /// Reads the persisted preference. Falls back to `.system`.
    static var current: AppLanguage {
        let stored = UserDefaults.standard.string(forKey: AppLanguage.storageKey)
        return AppLanguage(rawValue: stored ?? "") ?? .system
    }

    /// UserDefaults key that stores the user's choice (rawValue of AppLanguage).
    static let storageKey = "com.wesk.vtool.appLanguage"

    /// UserDefaults key consumed by Foundation's locale machinery.
    static let appleLanguagesKey = "AppleLanguages"
}

@MainActor
final class LanguageManager: ObservableObject {
    @Published var language: AppLanguage

    init() {
        let initial = AppLanguage.current
        self.language = initial
        // `didSet` is not invoked during `init`, so call apply explicitly.
        LanguageManager.applyToUserDefaults(initial)
    }

    /// Persists the choice and updates `AppleLanguages` in UserDefaults.
    /// The UI language changes on the *next* app launch.
    static func applyToUserDefaults(_ value: AppLanguage) {
        UserDefaults.standard.set(value.rawValue, forKey: AppLanguage.storageKey)

        if let languages = value.appleLanguagesValue {
            UserDefaults.standard.set(languages, forKey: AppLanguage.appleLanguagesKey)
        } else {
            // Remove the override so the system preference is used again.
            UserDefaults.standard.removeObject(forKey: AppLanguage.appleLanguagesKey)
        }
    }

    /// Whether the running app's effective language already matches the
    /// persisted preference. Used to decide whether to show a "restart"
    /// hint to the user.
    var needsRestart: Bool {
        let preferred = Locale.preferredLanguages
        switch language {
        case .system:
            // "Follow System" never needs a restart — the system language
            // is always the fallback when no override is set.
            return false
        case .zhHans:
            return !preferred.contains(where: { $0.hasPrefix("zh-Hans") || $0 == "zh" })
        case .en:
            return !preferred.contains(where: { $0.hasPrefix("en") })
        }
    }
}
