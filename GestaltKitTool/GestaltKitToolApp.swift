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

        // Headless self-test for device validation: 5s after launch, run
        // the carrier-bundle (IPCC) probe, a keychain reachability probe
        // and a MobileGestalt dashboard dump; all results are mirrored to
        // syslog ([GKTL-ObjC] / [GKTL-Keychain] / [GKTL-Dashboard]).
        // Opt-in only — enable with
        // `defaults write com.wesk.vtool GKTLAutoProbe -bool YES`.
        if UserDefaults.standard.object(forKey: "GKTLAutoProbe") as? Bool ?? false {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                Task { @MainActor in
                    let model = DiagnosticsModel()
                    model.runCarrierProbe()
                }
                // Keychain reachability probe — fully automated, all
                // results mirrored to syslog as [GKTL-Keychain].
                Task { @MainActor in
                    let probe = KeychainProbeModel()
                    probe.run()
                }
                // Device dashboard dump — mirrors the MobileGestalt
                // values to syslog as [GKTL-Dashboard] rows.
                Task { @MainActor in
                    let dashboard = DeviceDashboardModel()
                    dashboard.runOnRead = { rows in
                        for row in rows.prefix(25) {
                            gktlLog("[GKTL-Dashboard] ROW \(row.key) = \(row.displayValue)")
                        }
                        gktlLog("[GKTL-Dashboard] total rows=\(rows.count)")
                    }
                    dashboard.run()
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(languageManager)
        }
    }
}
