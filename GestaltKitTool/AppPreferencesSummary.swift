//
//  AppPreferencesSummary.swift
//  GestaltKitTool
//
//  Reads every plist under an app container's Preferences/ directory
//  and flattens all keys/values into a searchable list.
//

import Combine
import Foundation

struct AppPreferenceEntry: Identifiable, Hashable {
    let file: String      // plist file name
    let key: String       // full dotted key path
    let value: String     // display value
    var id: String { "\(file)#\(key)" }
}

@MainActor
final class AppPreferencesSummarizer: ObservableObject {

    @Published private(set) var entries: [AppPreferenceEntry] = []
    @Published private(set) var isRunning = false
    @Published private(set) var errorText: String?
    @Published private(set) var filesRead = 0

    private let fileAccess = BadQueryFileAccess.shared()

    func summarize(containerPath: String) {
        guard !isRunning else { return }
        isRunning = true
        errorText = nil
        entries = []
        filesRead = 0

        let fa = fileAccess
        Task.detached(priority: .userInitiated) { [weak self] in
            // iOS app prefs live under <container>/Preferences, but
            // some apps also use Library/Preferences — check both.
            var result: [AppPreferenceEntry] = []
            var filesRead = 0
            for prefsDir in [
                (containerPath as NSString).appendingPathComponent("Preferences"),
                (containerPath as NSString).appendingPathComponent("Library/Preferences")
            ] {
                let files = fa.listDirectoryNoFallback(atPath: prefsDir, error: nil)
                    .filter { !$0.isDirectory && $0.name.hasSuffix(".plist") }
                for file in files {
                    guard let data = try? fa.readFile(atPath: file.fullPath as String),
                          let plist = (try? PropertyListSerialization.propertyList(
                              from: data, options: [], format: nil)) as? [String: Any]
                    else { continue }
                    filesRead += 1
                    Self.flatten(file: file.name, dict: plist, prefix: "", into: &result)
                }
            }

            gktlLog("[GKTL-PrefSummary] done: \(result.count) entries from \(filesRead) files")

            await MainActor.run {
                self?.entries = result
                self?.filesRead = filesRead
                self?.isRunning = false
                if result.isEmpty {
                    self?.errorText = String(localized: "No readable preference plists in this container.")
                }
            }
        }
    }

    /// Recursively flattens a plist dict into dotted-path entries.
    private nonisolated static func flatten(
        file: String,
        dict: [String: Any],
        prefix: String,
        into out: inout [AppPreferenceEntry]
    ) {
        for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
            let key = prefix.isEmpty ? k : "\(prefix).\(k)"
            if let sub = v as? [String: Any] {
                flatten(file: file, dict: sub, prefix: key, into: &out)
            } else if let arr = v as? [Any] {
                for (i, item) in arr.enumerated() {
                    out.append(AppPreferenceEntry(
                        file: file,
                        key: "\(key)[\(i)]",
                        value: Self.displayValue(item)
                    ))
                }
            } else {
                out.append(AppPreferenceEntry(
                    file: file,
                    key: key,
                    value: Self.displayValue(v)
                ))
            }
        }
    }

    /// Compact display for a plist value (truncated for rows).
    private nonisolated static func displayValue(_ v: Any) -> String {
        if let s = v as? String { return s.count > 120 ? String(s.prefix(120)) + "…" : s }
        if let d = v as? Date {
            return d.description(with: Locale.current)
        }
        if let data = v as? Data {
            return String(format: String(localized: "<%d bytes>"), data.count)
        }
        return String(describing: v)
    }
}
