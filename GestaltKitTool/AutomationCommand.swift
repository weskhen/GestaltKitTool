import Foundation

/// Headless command-line automation for GestaltKitTool.
///
/// Supported arguments:
///   `--set-us-region <A1234>`        Set US region keys (LL, LL/A, regulatory model).
///   `--enable-tweak <id>`            Enable a tweak by its GestaltTweakID raw value.
///   `--disable-tweak <id>`           Disable (revert) a tweak by its GestaltTweakID raw value.
///   `--set-dynamic-island <subtype>` Set ArtworkDeviceSubType to the given integer.
///   `--set-model-name <name>`        Set DeviceModelName in CacheExtra.
///   `--restore-factory`              Revert all tweaks to factory defaults.
///   `--list-tweaks`                   Print all available tweak IDs and titles.
///
/// Each command performs: connect → read → mutate → backup → write → verify → exit.
/// The result marker is written to stdout so the calling process can
/// detect success or failure programmatically.
enum AutomationCommand {
    static let successMarker = "GESTALT_SUCCESS"
    static let failureMarker = "GESTALT_FAILURE"

    static func runIfNeeded() {
        let arguments = CommandLine.arguments

        // --set-us-region <A1234>
        if let commandIndex = arguments.firstIndex(of: "--set-us-region") {
            runSetUSRegion(arguments: arguments, commandIndex: commandIndex)
        }

        // --enable-tweak <id>
        if let commandIndex = arguments.firstIndex(of: "--enable-tweak") {
            runEnableTweak(arguments: arguments, commandIndex: commandIndex)
        }

        // --disable-tweak <id>
        if let commandIndex = arguments.firstIndex(of: "--disable-tweak") {
            runDisableTweak(arguments: arguments, commandIndex: commandIndex)
        }

        // --set-dynamic-island <subtype>
        if let commandIndex = arguments.firstIndex(of: "--set-dynamic-island") {
            runSetDynamicIsland(arguments: arguments, commandIndex: commandIndex)
        }

        // --set-model-name <name>
        if let commandIndex = arguments.firstIndex(of: "--set-model-name") {
            runSetModelName(arguments: arguments, commandIndex: commandIndex)
        }

        // --restore-factory
        if arguments.contains("--restore-factory") {
            runRestoreFactory()
        }

        // --list-tweaks
        if arguments.contains("--list-tweaks") {
            runListTweaks()
        }
    }

    // MARK: - Shared Headless Apply Helper

    /// Performs a headless Gestalt plist mutation with backup, write, and
    /// verification — the same pipeline used by the UI's
    /// `GestaltViewModel.save()`, but without MainActor/UI state.
    ///
    /// `mutate` receives the pending plist and should apply the desired
    /// changes. It may throw to signal failure.
    ///
    /// `verify` receives the re-read plist after saving and should throw
    /// if the expected values didn't stick. If nil, only the basic
    /// plist-validity check runs.
    private static func headlessApply(
        mutate: (inout GestaltPlist) throws -> Void,
        verify: ((GestaltPlist) throws -> Void)? = nil
    ) -> Bool {
        do {
            let access = GestaltAccess.shared()
            try access.connect()

            let originalData = try access.readGestaltData()
            guard let dict = try access.readGestalt() as? [String: Any] else {
                throw AutomationError.invalidPlist
            }
            var plist = GestaltPlist(dict: dict)

            try mutate(&plist)

            // Backup before writing.
            _ = try GestaltBackupStore.create(from: originalData)
            try access.saveGestalt(plist.dict)

            // Verify: re-read and check.
            guard let verification = try access.readGestalt() as? [String: Any] else {
                throw AutomationError.verificationFailed
            }
            let verifiedPlist = GestaltPlist(dict: verification)

            // Strict check: caller-provided verification if any.
            if let verify {
                try verify(verifiedPlist)
            }

            return true
        } catch {
            // finish() returns Never, so the catch branch is non-returning.
            finish(marker: failureMarker, message: ErrorHandler.friendlyMessage(for: error))
        }
    }

    // MARK: - --set-us-region

    private static func runSetUSRegion(arguments: [String], commandIndex: Int) {
        let modelIndex = arguments.index(after: commandIndex)
        guard modelIndex < arguments.endIndex else {
            finish(marker: failureMarker, message: "Missing regulatory model")
            return
        }

        let regulatoryModel = arguments[modelIndex]
        guard regulatoryModel.wholeMatch(of: /^A\d{4}$/) != nil else {
            finish(marker: failureMarker, message: "Invalid regulatory model: \(regulatoryModel)")
            return
        }

        let ok = headlessApply(
            mutate: { plist in
                plist.setCacheExtra("LL", forKey: "h63QSdBCiT/z0WU6rdQv6Q")
                plist.setCacheExtra("LL/A", forKey: "yK+xavymRGZ3xWc1tb8XDg")
                plist.setCacheExtra(regulatoryModel, forKey: "97JDvERpVwO+GHtthIh7hA")
            },
            verify: { verifiedPlist in
                guard verifiedPlist.cacheExtra["h63QSdBCiT/z0WU6rdQv6Q"] as? String == "LL",
                      verifiedPlist.cacheExtra["yK+xavymRGZ3xWc1tb8XDg"] as? String == "LL/A",
                      verifiedPlist.cacheExtra["97JDvERpVwO+GHtthIh7hA"] as? String == regulatoryModel else {
                    throw AutomationError.verificationFailed
                }
            }
        )

        if ok {
            finish(marker: successMarker, message: regulatoryModel)
        }
    }

    // MARK: - --enable-tweak <id>

    private static func runEnableTweak(arguments: [String], commandIndex: Int) {
        let idIndex = arguments.index(after: commandIndex)
        guard idIndex < arguments.endIndex else {
            finish(marker: failureMarker, message: "Missing tweak ID")
            return
        }
        let rawID = arguments[idIndex]
        guard let tweakID = GestaltTweakID(rawValue: rawID),
              let definition = GestaltTweakCatalog.definition(for: tweakID) else {
            finish(marker: failureMarker, message: "Unknown tweak ID: \(rawID)")
            return
        }

        let ok = headlessApply { plist in
            try plist.apply(definition: definition)
        }

        if ok {
            finish(marker: successMarker, message: "Enabled: \(definition.title)")
        }
    }

    // MARK: - --disable-tweak <id>

    private static func runDisableTweak(arguments: [String], commandIndex: Int) {
        let idIndex = arguments.index(after: commandIndex)
        guard idIndex < arguments.endIndex else {
            finish(marker: failureMarker, message: "Missing tweak ID")
            return
        }
        let rawID = arguments[idIndex]
        guard let tweakID = GestaltTweakID(rawValue: rawID),
              let definition = GestaltTweakCatalog.definition(for: tweakID) else {
            finish(marker: failureMarker, message: "Unknown tweak ID: \(rawID)")
            return
        }

        let ok = headlessApply { plist in
            plist.revert(definition: definition)
        }

        if ok {
            finish(marker: successMarker, message: "Disabled: \(definition.title)")
        }
    }

    // MARK: - --set-dynamic-island <subtype>

    private static func runSetDynamicIsland(arguments: [String], commandIndex: Int) {
        let subIndex = arguments.index(after: commandIndex)
        guard subIndex < arguments.endIndex else {
            finish(marker: failureMarker, message: "Missing subtype")
            return
        }
        guard let subtype = Int(arguments[subIndex]) else {
            finish(marker: failureMarker, message: "Invalid subtype: \(arguments[subIndex])")
            return
        }

        let ok = headlessApply { plist in
            try plist.setDynamicIslandSubtype(subtype)
        }

        if ok {
            finish(marker: successMarker, message: "Dynamic Island subtype: \(subtype)")
        }
    }

    // MARK: - --set-model-name <name>

    private static func runSetModelName(arguments: [String], commandIndex: Int) {
        let nameIndex = arguments.index(after: commandIndex)
        guard nameIndex < arguments.endIndex else {
            finish(marker: failureMarker, message: "Missing model name")
            return
        }
        let name = arguments[nameIndex]
        
        switch ModelNameValidator.validate(name) {
        case .ok:
            break
        case .empty:
            finish(marker: failureMarker, message: "Model name cannot be empty")
            return
        case .tooLong:
            finish(marker: failureMarker, message: "Model name too long (max 50 characters)")
            return
        case .invalidCharacters:
            finish(marker: failureMarker, message: "Model name contains invalid characters (allowed: letters, numbers, spaces, -.,()'")
            return
        }

        let ok = headlessApply { plist in
            try plist.setModelName(name)
        }

        if ok {
            finish(marker: successMarker, message: "Model name: \(name)")
        }
    }

    // MARK: - --restore-factory

    private static func runRestoreFactory() {
        let ok = headlessApply { plist in
            plist.revertAllTweaks()
        }

        if ok {
            finish(marker: successMarker, message: "Factory settings restored")
        }
    }

    // MARK: - --list-tweaks

    private static func runListTweaks() {
        var output = "Available tweaks:\n"
        for def in GestaltTweakCatalog.definitions {
            output += "  \(def.id.rawValue) — \(def.title)\n"
        }
        FileHandle.standardOutput.write(Data(output.utf8))
        exit(EXIT_SUCCESS)
    }

    // MARK: - Finish

    /// Writes the result marker and message to stdout, then exits.
    /// This function is `-> Never` and calls `exit()` — the Swift
    /// compiler treats it as a non-returning function, so `guard else`
    /// blocks that call `finish()` are automatically treated as
    /// non-fall-through. Do NOT refactor this to return early without
    /// updating all call sites to add explicit `return` statements.
    private static func finish(marker: String, message: String) -> Never {
        let sanitized = message.replacingOccurrences(of: "\n", with: " ")
        let output = "\(marker):\(sanitized)\n"
        FileHandle.standardOutput.write(Data(output.utf8))
        exit(marker == successMarker ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}

private enum AutomationError: LocalizedError {
    case invalidPlist
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidPlist:
            return "MobileGestalt plist or CacheExtra is invalid"
        case .verificationFailed:
            return "MobileGestalt verification failed"
        }
    }
}
