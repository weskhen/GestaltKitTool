import SwiftUI

/// A wizard that guides the user through the full Siri AI (Apple Intelligence)
/// enablement flow. The tool handles the region rewrite (and device spoofing
/// when required); the user manually completes the account/language steps
/// that sandbox restrictions make impossible to automate.
struct SiriAIWizardView: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var eligibilitySummary: String?
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            List {
                stepSection(
                    number: 1,
                    titleKey: String(localized: "Region Rewrite"),
                    done: regionRewriteDone
                ) {
                    Text(String(localized: "Tool step — already automated. Writes region keys (LL / LL/A / regulatory model) into the MobileGestalt cache. Survives reboot."))
                }

                stepSection(
                    number: 2,
                    titleKey: String(localized: "Language & Siri"),
                    done: languageDone
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "Manual step. Settings → General → Language & Region → set to English (US). Then Settings → Siri → Language → English (United States)."))
                        Text(String(localized: "The tool cannot do this for you: the Preferences directory only grants read-only sandbox extensions."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                stepSection(
                    number: 3,
                    titleKey: String(localized: "Sign In to US Apple ID"),
                    done: nil
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "Manual step. Settings → sign in with an Apple ID whose account region is United States. An iCloud account in a different region will keep the AI domain in a transient state."))
                        Text(String(localized: "Apple ID sign-in involves passwords and two-factor authentication — no tool should automate this."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        refreshEligibility()
                    } label: {
                        HStack {
                            if isRefreshing { ProgressView().padding(.trailing, 4) }
                            Text(String(localized: "Refresh Eligibility Status"))
                        }
                    }
                    .disabled(isRefreshing)

                    if let eligibilitySummary {
                        Text(eligibilitySummary)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text(String(localized: "Eligibility Check"))
                } footer: {
                    Text(String(localized: "FOUNDATION_MODELS / GREYMATTER answer: 4 = transient (inputs incomplete), 2 = eligible. Re-run after completing the manual steps and rebooting."))
                }
            }
            .navigationTitle(String(localized: "Siri AI Setup Guide"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }

    // MARK: - Step state

    private var regionRewriteDone: Bool {
        // Region is considered done when the loaded plist already carries LL.
        guard let plist = viewModel.plist else { return false }
        return plist.cacheExtra["h63QSdBCiT/z0WU6rdQv6Q"] as? String == "LL"
    }

    private var languageDone: Bool {
        // Best-effort proxy: compare the current UI language. The authoritative
        // value lives in .GlobalPreferences (AppleLocale), which the app can
        // read via the file bridge, but locale here is a cheap first signal.
        let preferred = Locale.preferredLanguages.first ?? ""
        return preferred.hasPrefix("en")
    }

    private func stepSection(number: Int,
                             titleKey: String,
                             done: Bool?,
                             @ViewBuilder body: () -> some View) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(done == true ? Color.green.opacity(0.2) : Color.gray.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: done == true ? "checkmark" : "\(number).circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(done == true ? .green : .secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(titleKey).font(.headline)
                    body()
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Eligibility

    private func refreshEligibility() {
        isRefreshing = true
        let path = "/private/var/db/eligibilityd/eligibility.plist"
        let access = BadQueryFileAccess.shared()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                DispatchQueue.main.async { isRefreshing = false }
            }
            guard let data = try? access.readFile(atPath: path),
                  let dict = try? PropertyListSerialization.propertyList(
                    from: data, format: nil) as? [String: Any] else {
                DispatchQueue.main.async {
                    eligibilitySummary = String(localized: "eligibility.plist unreadable — sandbox extension not granted for this path.")
                }
                return
            }
            var lines: [String] = []
            for domain in ["OS_ELIGIBILITY_DOMAIN_FOUNDATION_MODELS",
                           "OS_ELIGIBILITY_DOMAIN_GREYMATTER"] {
                guard let entry = dict[domain] as? [String: Any] else { continue }
                let answer = entry["os_eligibility_answer_t"] ?? "?"
                lines.append("\(domain.replacingOccurrences(of: "OS_ELIGIBILITY_DOMAIN_", with: "")): answer=\(answer)")
                if let status = entry["status"] as? [String: Any] {
                    let inputs = status.keys
                        .filter { $0.hasPrefix("OS_ELIGIBILITY_INPUT_") }
                        .sorted()
                        .map { "\($0.replacingOccurrences(of: "OS_ELIGIBILITY_INPUT_", with: ""))=\(status[$0] ?? "?")" }
                        .joined(separator: " ")
                    lines.append("  \(inputs)")
                }
            }
            DispatchQueue.main.async {
                eligibilitySummary = lines.joined(separator: "\n")
            }
        }
    }
}
