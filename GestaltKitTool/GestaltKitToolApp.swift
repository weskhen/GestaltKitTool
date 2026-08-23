//
//  GestaltKitToolApp.swift
//  GestaltKitTool
//

import SwiftUI
import UIKit

/// On memory pressure, posts a custom notification that all cache-owning
/// models subscribe to and flush their caches.
enum MemoryPressureMonitor {
    static let didReceiveWarning = Notification.Name("GKTLMemoryPressureWarning")

    static func start() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: didReceiveWarning, object: nil)
        }
    }
}

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
        MemoryPressureMonitor.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(languageManager)
        }
    }
}
