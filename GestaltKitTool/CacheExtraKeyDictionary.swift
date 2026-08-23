//
//  CacheExtraKeyDictionary.swift
//  GestaltKitTool
//
//  Human-readable descriptions for CacheExtra keys.
//  Original keys are base64-encoded opaque identifiers; this maps them to short labels and descriptions.
//

import Foundation

enum CacheExtraKeyDictionary {

    /// A known CacheExtra key entry.
    struct Entry {
        let label: String           // Short human-readable label
        let description: String     // Longer explanation
        let category: String        // Grouping: "Display", "Hardware", etc.
    }

    /// The ArtworkDevice key (used by Dynamic Island & model name features).
    static let artworkDeviceKey = "oPeik/9e8lQWMszEjbPzng"

    /// Looks up a description for the given CacheExtra key.
    /// Returns nil if the key is unknown (third-party or undocumented).
    static func info(forKey key: String) -> Entry? {
        if key == artworkDeviceKey {
            return Entry(
                label: "ArtworkDevice",
                description: "Contains ArtworkDeviceSubType (Dynamic Island shape) and ArtworkDeviceProductDescription (model name in About). A nested dictionary — tap to edit individual sub-fields.",
                category: "Identity"
            )
        }
        return knownKeys[key]
    }

    // Use plain string constants — SwiftUI Text(_: LocalizedStringResource) and
    // String(localized:) will auto-localize these as keys in Localizable.strings.
    // We add the corresponding translations to the strings files.

    private static let knownKeys: [String: Entry] = [

        // MARK: - Display & Appearance

        "YlEtTtHlNesRBMal1CqRaA": .init(
            label: "Dynamic Island Support Flag",
            description: "Enables Dynamic Island capability. Set to 1 to enable, 0 to disable. Used together with ArtworkDeviceSubType.",
            category: "Display"),

        "2OOJf1VhaM7NxfRok3HbWQ": .init(
            label: "Always-On Display Flag 1",
            description: "First AOD capability flag. Set to 1 to enable Always-On Display. May increase burn-in risk on unsupported devices.",
            category: "Display"),

        "j8/Omm6s1lsmTDFsXjsBfA": .init(
            label: "Always-On Display Flag 2",
            description: "Second AOD capability flag. Set to 1 together with Flag 1 to fully enable AOD.",
            category: "Display"),

        "ykpu7qyhqFweVMKtxNylWA": .init(
            label: "AOD Vibrancy",
            description: "Fixes AOD rendering issues on certain devices. Set to 1 when AOD looks dim or incorrect.",
            category: "Display"),

        "UIParallaxCapability": .init(
            label: "Wallpaper Parallax",
            description: "Controls wallpaper motion parallax based on device tilt. Set to 0 to disable, 1 to enable.",
            category: "Display"),

        "SAGvsp6O6kAQ4fEfDJpC4Q": .init(
            label: "Liquid Glass Low-Performance Mode",
            description: "Controls the Liquid Glass low-performance rendering mode (iOS 26+). 1 = enabled, 0 = disabled. Enable/disable are mutually exclusive.",
            category: "Display"),

        // MARK: - Hardware Capabilities

        "QHxt+hGLaBPbQJbXiUJX3w": .init(
            label: "Boot & Shutdown Chime",
            description: "Enables the device boot and shutdown sound. Set to 1 to enable.",
            category: "Hardware"),

        "37NVydb//GP/GrhuTN+exg": .init(
            label: "Charge Limit Menu",
            description: "Shows the charge limit menu in Settings. Actual limiting depends on hardware support. Set to 1 to show.",
            category: "Hardware"),

        "yZf3GTRMGTuwSV/lD7Cagw": .init(
            label: "Tap to Wake",
            description: "Enables tap-to-wake on devices where it's unavailable (e.g. iPhone SE). Set to 1 to enable.",
            category: "Hardware"),

        "CwvKxM2cEogD3p+HYgaW0Q": .init(
            label: "Camera Control Settings 1",
            description: "Shows iPhone 16 Camera Control settings page. Set to 1 together with the second key.",
            category: "Hardware"),

        "oOV1jhJbdV3AddkcCg0AEA": .init(
            label: "Camera Control Settings 2",
            description: "Second Camera Control capability flag. Set to 1 together with the first key.",
            category: "Hardware"),

        "yhHcB0iH0d1XzPO/CFd3ow": .init(
            label: "Apple Pencil Settings",
            description: "Shows the Apple Pencil settings page. Set to 1 to enable.",
            category: "Hardware"),

        "cT44WE1EohiwRzhsZ8xEsw": .init(
            label: "Action Button Settings",
            description: "Shows the Action Button settings page. Set to 1 to enable.",
            category: "Hardware"),

        "HCzWusHQwZDea6nNhaKndw": .init(
            label: "Collision SOS",
            description: "Shows collision detection in SOS settings. Set to 1 to enable.",
            category: "Hardware"),

        // MARK: - iPad Capabilities

        "qeaj75wk3HF4DwQ8qbIi7g": .init(
            label: "Stage Manager Support",
            description: "Marks the device as supporting Stage Manager. Set to 1 to enable.",
            category: "iPad"),

        "9MZ5AdH43csAUajl/dU+IQ": .init(
            label: "Allow iPad Apps",
            description: "Enables iPad app compatibility types on iPhone. Value is an array: [1, 2] = enabled, [] = disabled.",
            category: "iPad"),

        "mG0AnH/Vy1veoqoLRAIgTA": .init(
            label: "iPadOS Mode Flag 1",
            description: "First of five capability flags for iPadOS mode. Experimental and high risk — modifies CacheData.",
            category: "iPad"),

        "UCG5MkVahJxG1YULbbd5Bg": .init(
            label: "iPadOS Mode Flag 2",
            description: "Second iPadOS mode capability flag. Part of the 5-flag iPadOS mode set.",
            category: "iPad"),

        "ZYqko/XM5zD3XBfN5RmaXA": .init(
            label: "iPadOS Mode Flag 3",
            description: "Third iPadOS mode capability flag.",
            category: "iPad"),

        "nVh/gwNpy7Jv1NOk00CMrw": .init(
            label: "iPadOS Mode Flag 4",
            description: "Fourth iPadOS mode capability flag.",
            category: "iPad"),

        "uKc7FPnEO++lVhHWHFlGbQ": .init(
            label: "iPadOS Mode Flag 5",
            description: "Fifth iPadOS mode capability flag.",
            category: "iPad"),

        // MARK: - Internal & Research

        "EqrsVvjcYDdxHBiQmGhAWw": .init(
            label: "Apple Internal Install",
            description: "Enables internal capabilities such as Metal HUD. Some system services may misbehave. High risk.",
            category: "Internal"),

        "LBJfwOEzExRxzlAnSuI7eg": .init(
            label: "Internal Storage View",
            description: "Shows internal files in Storage settings. High risk on some iPads.",
            category: "Internal"),

        "XYlJKKkj2hztRP1NWWnhlw": .init(
            label: "Security Research Device Mode",
            description: "Marks the device as a Security Research Device. High risk.",
            category: "Internal"),

        // MARK: - AI Region (Siri AI)

        "A62OafQ85EJAiiqKn4agtg": .init(
            label: "Siri AI Region Enabled",
            description: "Master flag for Siri AI (US Region). Set to 1 to enable, 0 to disable. Requires device spoofing on unsupported devices.",
            category: "AI Region"),

        "h9jDsbgj7xIVeIQ8S3/X3Q": .init(
            label: "Spoofed Product Type",
            description: "Product type used for AI Region spoofing (e.g. 'iPhone16,1'). Empty string = no spoofing.",
            category: "AI Region"),

        "oYicEKzVTz4/CxxE05pEgQ": .init(
            label: "Spoofed Hardware Model",
            description: "Hardware model for AI Region spoofing (e.g. 'D83AP'). Empty string = no spoofing.",
            category: "AI Region"),

        "5pYKlGnYYBzGvAlIU8RjEQ": .init(
            label: "Spoofed CPU Model",
            description: "CPU model for AI Region spoofing (e.g. 't8130'). Empty string = no spoofing.",
            category: "AI Region"),

        "h63QSdBCiT/z0WU6rdQv6Q": .init(
            label: "Region Code",
            description: "Region code for AI Region (e.g. 'LL' = US). Empty string = default.",
            category: "AI Region"),

        "yK+xavymRGZ3xWc1tb8XDg": .init(
            label: "Regulatory Code",
            description: "Regulatory certification code for AI Region (e.g. 'LL/A' = US/FCC). Empty string = default.",
            category: "AI Region"),

        "97JDvERpVwO+GHtthIh7hA": .init(
            label: "Regulatory Model Number",
            description: "Regulatory model number for AI Region (e.g. 'A2848' = iPhone 15 Pro US). Empty string = default.",
            category: "AI Region"),
    ]
}
