import Foundation

enum GestaltTweakCategory: String, CaseIterable, Identifiable {
    case region
    case display
    case hardware
    case ipad
    case internalFeatures

    var id: String { rawValue }

    var label: String {
        switch self {
        case .display: String(localized: "Display & Appearance")
        case .hardware: String(localized: "Hardware Capabilities")
        case .ipad: String(localized: "iPad Capabilities")
        case .region: String(localized: "Region")
        case .internalFeatures: String(localized: "Internal & Research")
        }
    }
}

enum GestaltTweakID: String, CaseIterable, Identifiable {
    case supportsDynamicIsland
    case bootChime
    case chargeLimit
    case tapToWake
    case cameraButton
    case disableParallax
    case enableLiquidGlassLowPerformance
    case disableLiquidGlassLowPerformance
    case stageManager
    case iPadOS
    case iPadApps
    case pencil
    case actionButton
    case internalInstall
    case internalStorage
    case securityResearchDevice
    case collisionSOS
    case alwaysOnDisplay
    case alwaysOnDisplayVibrancy

    var id: String { rawValue }
}

struct GestaltTweakDefinition: Identifiable {
    let id: GestaltTweakID
    let category: GestaltTweakCategory
    let title: String
    let detail: String
    let values: [String: Any]
    var isRisky = false
}

enum GestaltTweakCatalog {
    static let definitions: [GestaltTweakDefinition] = [
        .init(id: .supportsDynamicIsland, category: .display, title: String(localized: "Enable Dynamic Island Capability"), detail: String(localized: "Nugget's alternate enable method."), values: ["YlEtTtHlNesRBMal1CqRaA": 1]),
        .init(id: .alwaysOnDisplay, category: .display, title: String(localized: "Always-On Display"), detail: String(localized: "May increase burn-in risk on unsupported devices."), values: ["2OOJf1VhaM7NxfRok3HbWQ": 1, "j8/Omm6s1lsmTDFsXjsBfA": 1], isRisky: true),
        .init(id: .alwaysOnDisplayVibrancy, category: .display, title: String(localized: "AOD Vibrancy"), detail: String(localized: "Use this when AOD rendering looks incorrect."), values: ["ykpu7qyhqFweVMKtxNylWA": 1]),
        .init(id: .disableParallax, category: .display, title: String(localized: "Disable Wallpaper Parallax"), detail: String(localized: "Stops wallpaper motion based on device movement."), values: ["UIParallaxCapability": 0]),
        .init(id: .enableLiquidGlassLowPerformance, category: .display, title: String(localized: "Enable Liquid Glass Low-Performance Mode"), detail: String(localized: "For iOS 26 and later."), values: ["SAGvsp6O6kAQ4fEfDJpC4Q": 1]),
        .init(id: .disableLiquidGlassLowPerformance, category: .display, title: String(localized: "Disable Liquid Glass Low-Performance Mode"), detail: String(localized: "Mutually exclusive with the option above."), values: ["SAGvsp6O6kAQ4fEfDJpC4Q": 0]),

        .init(id: .bootChime, category: .hardware, title: String(localized: "Boot & Shutdown Chime"), detail: String(localized: "Enables the device boot and shutdown chime capability."), values: ["QHxt+hGLaBPbQJbXiUJX3w": 1]),
        .init(id: .chargeLimit, category: .hardware, title: String(localized: "Charge Limit Menu"), detail: String(localized: "Shows the Settings menu; actual limiting depends on hardware."), values: ["37NVydb//GP/GrhuTN+exg": 1]),
        .init(id: .tapToWake, category: .hardware, title: String(localized: "Tap to Wake"), detail: String(localized: "Primarily for models such as iPhone SE where it is unavailable."), values: ["yZf3GTRMGTuwSV/lD7Cagw": 1]),
        .init(id: .cameraButton, category: .hardware, title: String(localized: "iPhone 16 Camera Control Settings"), detail: String(localized: "Shows Camera Control settings and related capabilities."), values: ["CwvKxM2cEogD3p+HYgaW0Q": 1, "oOV1jhJbdV3AddkcCg0AEA": 1]),
        .init(id: .pencil, category: .hardware, title: String(localized: "Apple Pencil Settings"), detail: String(localized: "Shows the Apple Pencil settings page."), values: ["yhHcB0iH0d1XzPO/CFd3ow": 1]),
        .init(id: .actionButton, category: .hardware, title: String(localized: "Action Button Settings"), detail: String(localized: "Shows the Action Button settings page."), values: ["cT44WE1EohiwRzhsZ8xEsw": 1]),
        .init(id: .collisionSOS, category: .hardware, title: String(localized: "Collision SOS"), detail: String(localized: "Shows collision detection in SOS settings."), values: ["HCzWusHQwZDea6nNhaKndw": 1]),

        .init(id: .stageManager, category: .ipad, title: String(localized: "Stage Manager Support"), detail: String(localized: "Marks the device as supporting Stage Manager."), values: ["qeaj75wk3HF4DwQ8qbIi7g": 1]),
        .init(id: .iPadApps, category: .ipad, title: String(localized: "Allow iPad Apps"), detail: String(localized: "Enables iPad app compatibility types on iPhone."), values: ["9MZ5AdH43csAUajl/dU+IQ": [1, 2]]),
        .init(id: .iPadOS, category: .ipad, title: String(localized: "Enable iPadOS Mode"), detail: String(localized: "Changes five capabilities and CacheData; experimental and high risk."), values: ["mG0AnH/Vy1veoqoLRAIgTA": 1, "UCG5MkVahJxG1YULbbd5Bg": 1, "ZYqko/XM5zD3XBfN5RmaXA": 1, "nVh/gwNpy7Jv1NOk00CMrw": 1, "uKc7FPnEO++lVhHWHFlGbQ": 1], isRisky: true),

        .init(id: .internalInstall, category: .internalFeatures, title: String(localized: "Apple Internal Install"), detail: String(localized: "Enables internal capabilities such as Metal HUD; some services may misbehave."), values: ["EqrsVvjcYDdxHBiQmGhAWw": 1], isRisky: true),
        .init(id: .internalStorage, category: .internalFeatures, title: String(localized: "Internal Storage View"), detail: String(localized: "Shows internal files in Storage settings; high risk on some iPads."), values: ["LBJfwOEzExRxzlAnSuI7eg": 1], isRisky: true),
        .init(id: .securityResearchDevice, category: .internalFeatures, title: String(localized: "Security Research Device Mode"), detail: String(localized: "Marks the device as a Security Research Device."), values: ["XYlJKKkj2hztRP1NWWnhlw": 1], isRisky: true)
    ]

    static func definition(for id: GestaltTweakID) -> GestaltTweakDefinition? {
        definitions.first { $0.id == id }
    }
}

struct DynamicIslandOption: Identifiable, Hashable {
    let subtype: Int
    let title: String
    var id: Int { subtype }

    static let all: [DynamicIslandOption] = [
        .init(subtype: 2436, title: "iPhone X Gestures (SE)"),
        .init(subtype: 2556, title: "iPhone 14 Pro"),
        .init(subtype: 2796, title: "iPhone 14 Pro Max"),
        .init(subtype: 2622, title: "iPhone 16 Pro"),
        .init(subtype: 2868, title: "iPhone 16 Pro Max"),
        .init(subtype: 2736, title: "iPhone Air")
    ]
}

enum GestaltTweakError: LocalizedError {
    case artworkDictionaryMissing
    case cacheDataMissing
    case cacheDataTooShort
    case cacheDataPatternNotFound
    case invalidCacheDataOffset

    var errorDescription: String? {
        switch self {
        case .artworkDictionaryMissing: String(localized: "MobileGestalt is missing the ArtworkDevice dictionary, so Dynamic Island or model name cannot be changed.")
        case .cacheDataMissing: String(localized: "MobileGestalt is missing CacheData, so iPadOS mode cannot be enabled.")
        case .cacheDataTooShort: String(localized: "CacheData is too short to apply iPadOS mode safely.")
        case .cacheDataPatternNotFound: String(localized: "The iPadOS marker required by Nugget was not found in CacheData.")
        case .invalidCacheDataOffset: String(localized: "CacheData marker validation failed. No changes were made.")
        }
    }
}

extension GestaltPlist {
    mutating func apply(definition: GestaltTweakDefinition) throws {
        for (key, value) in definition.values {
            setCacheExtra(value, forKey: key)
        }
        if definition.id == .iPadOS {
            try enableIPadOSCacheData()
        }
    }

    /// Reverts a previously-applied tweak by writing the *opposite* value
    /// for each CacheExtra key. For example, a capability key that was set
    /// to `1` (enabled) is written as `0` (disabled).
    ///
    /// We explicitly write `0` rather than removing the key, because the
    /// MobileGestalt daemon regenerates missing keys with their *default*
    /// values — which for capability flags is often `1` (enabled). Removing
    /// the key would therefore cause the tweak to silently re-apply itself
    /// on the next daemon sync. Writing `0` persists the "disabled" state.
    ///
    /// For the iPadOS tweak, the CacheData byte patch is left untouched —
    /// it is not safely reversible without the original bytes. Users should
    /// restore from a backup to fully undo iPadOS mode.
    mutating func revert(definition: GestaltTweakDefinition) {
        for (key, value) in definition.values {
            setCacheExtra(opposite(of: value), forKey: key)
        }
    }

    /// Returns the "disabled" counterpart of a tweak value.
    /// - `1` → `0` (capability flag off)
    /// - `0` → `1` (if the tweak itself was a "disable" type)
    /// - Arrays → empty array
    /// - Other values are returned as-is (no known opposite).
    private func opposite(of value: Any) -> Any {
        if let n = value as? NSNumber {
            if n.intValue == 1 { return NSNumber(value: 0) }
            if n.intValue == 0 { return NSNumber(value: 1) }
            return n
        }
        if value is NSArray {
            // Array values (e.g. iPadApps [1,2]) → empty array = disabled
            return NSArray()
        }
        return value
    }

    mutating func setDynamicIslandSubtype(_ subtype: Int) throws {
        let key = "oPeik/9e8lQWMszEjbPzng"
        guard var artwork = cacheExtra[key] as? [String: Any] else {
            throw GestaltTweakError.artworkDictionaryMissing
        }
        artwork["ArtworkDeviceSubType"] = subtype
        setCacheExtra(artwork, forKey: key)
        setCacheExtra(1, forKey: "YlEtTtHlNesRBMal1CqRaA")
    }

    /// Reverts Dynamic Island customization by setting the support flag
    /// to `0` (disabled) and clearing the subtype. We write `0` rather
    /// than removing the keys because the MobileGestalt daemon
    /// regenerates missing keys with default values.
    mutating func revertDynamicIsland() {
        let key = "oPeik/9e8lQWMszEjbPzng"
        if var artwork = cacheExtra[key] as? [String: Any] {
            artwork["ArtworkDeviceSubType"] = 0
            setCacheExtra(artwork, forKey: key)
        }
        setCacheExtra(0, forKey: "YlEtTtHlNesRBMal1CqRaA")
    }

    mutating func setModelName(_ name: String) throws {
        let key = "oPeik/9e8lQWMszEjbPzng"
        guard var artwork = cacheExtra[key] as? [String: Any] else {
            throw GestaltTweakError.artworkDictionaryMissing
        }
        artwork["ArtworkDeviceProductDescription"] = name
        setCacheExtra(artwork, forKey: key)
    }

    /// Reverts model name customization by clearing the product
    /// description string. We write an empty string rather than removing
    /// the key because the daemon may regenerate it.
    mutating func revertModelName() {
        let key = "oPeik/9e8lQWMszEjbPzng"
        if var artwork = cacheExtra[key] as? [String: Any] {
            artwork["ArtworkDeviceProductDescription"] = ""
            setCacheExtra(artwork, forKey: key)
        }
    }

    /// Reverts Siri AI (US Region) spoofing by writing `0` / empty
    /// strings for all the keys that were set during the AI region
    /// stage. We write disabled values rather than removing the keys
    /// because the MobileGestalt daemon regenerates missing keys.
    mutating func revertAIRegion() {
        setCacheExtra(0, forKey: "A62OafQ85EJAiiqKn4agtg")
        setCacheExtra("", forKey: "h9jDsbgj7xIVeIQ8S3/X3Q")
        setCacheExtra("", forKey: "oYicEKzVTz4/CxxE05pEgQ")
        setCacheExtra("", forKey: "5pYKlGnYYBzGvAlIU8RjEQ")
        setCacheExtra("", forKey: "h63QSdBCiT/z0WU6rdQv6Q")
        setCacheExtra("", forKey: "yK+xavymRGZ3xWc1tb8XDg")
        setCacheExtra("", forKey: "97JDvERpVwO+GHtthIh7hA")
    }

    /// Reverts **all** known tweaks to their disabled / factory state.
    /// This is used by the "Restore Factory Settings" feature to reset
    /// every capability flag, Dynamic Island, model name, and AI Region
    /// spoofing in one shot.
    ///
    /// Note: the iPadOS CacheData byte patch is not reversible — users
    /// who enabled iPadOS mode should restore from a backup taken before
    /// enabling it.
    mutating func revertAllTweaks() {
        // Track which CacheExtra keys have already been reverted so
        // that mutually exclusive definitions targeting the same key
        // (e.g. enable/disable Liquid Glass Low-Performance) don't
        // overwrite each other with contradictory values.
        var revertedKeys = Set<String>()
        for definition in GestaltTweakCatalog.definitions {
            let keys = Set(definition.values.keys)
            if !keys.isDisjoint(with: revertedKeys) { continue }
            revert(definition: definition)
            revertedKeys.formUnion(keys)
        }
        revertDynamicIsland()
        revertModelName()
        revertAIRegion()
    }

    private mutating func enableIPadOSCacheData() throws {
        guard let cacheData = dict["CacheData"] as? Data else {
            throw GestaltTweakError.cacheDataMissing
        }
        var hex = Array(cacheData.map { String(format: "%02x", $0) }.joined())
        let sliceStart = 1616
        let sliceLength = 200
        guard hex.count > sliceStart else { throw GestaltTweakError.cacheDataTooShort }

        let end = min(hex.count, sliceStart + sliceLength)
        let slice = String(hex[sliceStart..<end])
        let regex = try NSRegularExpression(pattern: "0+(?:5555)*([0-9a-f]{4})")
        let nsRange = NSRange(slice.startIndex..<slice.endIndex, in: slice)
        var matchedOffset: Int?
        regex.enumerateMatches(in: slice, range: nsRange) { match, _, stop in
            guard let range = match.flatMap({ Range($0.range(at: 1), in: slice) }) else { return }
            let value = slice[range]
            if value.filter({ $0 != "0" }).count >= 3 {
                matchedOffset = sliceStart + slice.distance(from: slice.startIndex, to: range.lowerBound)
                stop.pointee = true
            }
        }
        guard let offset = matchedOffset else { throw GestaltTweakError.cacheDataPatternNotFound }

        let rightOffset = offset + 13
        let leftOffset = offset - 67
        guard leftOffset > 0, rightOffset < hex.count - 1 else {
            throw GestaltTweakError.invalidCacheDataOffset
        }
        for position in [leftOffset, rightOffset] {
            guard ["1", "3"].contains(String(hex[position])),
                  hex[position - 1] == "0", hex[position + 1] == "0" else {
                throw GestaltTweakError.invalidCacheDataOffset
            }
        }
        hex[leftOffset] = "3"
        let updatedHex = String(hex)
        var updatedData = Data(capacity: updatedHex.count / 2)
        var index = updatedHex.startIndex
        while index < updatedHex.endIndex {
            let next = updatedHex.index(index, offsetBy: 2)
            guard let byte = UInt8(updatedHex[index..<next], radix: 16) else {
                throw GestaltTweakError.invalidCacheDataOffset
            }
            updatedData.append(byte)
            index = next
        }
        dict["CacheData"] = updatedData
    }
}
