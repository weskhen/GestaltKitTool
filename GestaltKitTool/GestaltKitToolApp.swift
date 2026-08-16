//
//  GestaltKitToolApp.swift
//  GestaltKitTool
//

import SwiftUI

@main
struct GestaltKitToolApp: App {
    @StateObject private var viewModel = GestaltViewModel()
    @StateObject private var languageManager = LanguageManager()

    init() {
        // Ensure the persisted language override is reflected in
        // UserDefaults before any localized string is resolved.
        let stored = AppLanguage.current
        if let languages = stored.appleLanguagesValue {
            UserDefaults.standard.set(languages, forKey: AppLanguage.appleLanguagesKey)
        }
        AutomationCommand.runIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(languageManager)
        }
    }
}
