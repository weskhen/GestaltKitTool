import SwiftUI

// MARK: - DesignConstants

/// Centralized design tokens for GestaltKitTool.
/// Prevents magic numbers and hardcoded colors from being scattered
/// across view files.
enum DesignConstants {
    static let emptyStateIconSize: CGFloat = 60

    static let heroIconSize: CGFloat = 60

    static let mediumIconSize: CGFloat = 44

    static let previewPlaceholderIconSize: CGFloat = 40

    static let errorListMaxHeight: CGFloat = 200

    nonisolated static let defaultMaxAppBackups: Int = 30

    // SQLite viewer pagination.
    static let sqlitePageSize: Int = 100

    // Hex viewer page size.
    static let hexPageSize: Int = 4096

    // File preview data prefix size.
    static let previewPrefixSize: Int = 4096

    // Max search results.
    static let maxSearchResults: Int = 200

    // Text truncation limit for SQLite TEXT display.
    static let sqliteTextTruncationLimit: Int = 2000

    // Hex preview byte limit for SystemInspector.
    static let hexPreviewByteLimit: Int = 8192

    // Export file max age in seconds (1 hour).
    static let exportMaxAge: TimeInterval = 3600

    // Max search depth for file explorer recursive search.
    static let maxSearchDepth: Int = 10
}

// MARK: - Semantic Colors

extension Color {
    /// Error or destructive action indicator.
    static let errorForeground = Color.red
    /// Subtle error background (e.g., alert banners).
    static let errorBackground = Color.red.opacity(0.1)
    /// Success or positive status indicator.
    static let successForeground = Color.green
    /// Failure indicator (alias of errorForeground for batch progress).
    static let failureIndicator = Color.red
}

// MARK: - UserDefaults Keys

enum UserDefaultsKeys {
    static let appBackups = "com.wesk.vtool.appbackups"
    static let explorerFavorites = "com.wesk.vtool.explorer.favorites"
    static let customQuickPaths = "com.wesk.vtool.explorer.customQuickPaths"
    static let appLanguage = "com.wesk.vtool.appLanguage"
    static let appleLanguages = "AppleLanguages"
    static let patches = "com.wesk.vtool.patches"
    static let backupLabels = "com.wesk.vtool.backupLabels"
    static let onboardingCompleted = "com.wesk.vtool.onboardingCompleted"
}

// MARK: - Shared Locale

enum SharedLocale {
    static let posix = Locale(identifier: "en_US_POSIX")
}

// MARK: - EmptyStateIcon

struct EmptyStateIcon: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: DesignConstants.emptyStateIconSize))
            .foregroundStyle(.secondary)
    }
}

extension View {
    func emptyStateIconStyle() -> some View {
        modifier(EmptyStateIcon())
    }
}

// MARK: - Unified Empty State View

/// Reusable empty-state placeholder with icon, title, description,
/// and optional CTA button. Provides consistent visual styling across
/// all list screens (Backups, Patches, Presets, etc.).
struct EmptyStateView: View {
    let icon: String
    let title: String
    let description: String
    let ctaTitle: String?
    let ctaAction: (() -> Void)?
    let ctaDisabled: Bool

    init(
        icon: String,
        title: String,
        description: String,
        ctaTitle: String? = nil,
        ctaAction: (() -> Void)? = nil,
        ctaDisabled: Bool = false
    ) {
        self.icon = icon
        self.title = title
        self.description = description
        self.ctaTitle = ctaTitle
        self.ctaAction = ctaAction
        self.ctaDisabled = ctaDisabled
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: DesignConstants.emptyStateIconSize))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let ctaTitle, let ctaAction {
                Button {
                    ctaAction()
                } label: {
                    Label(ctaTitle, systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(ctaDisabled)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
    }
}
