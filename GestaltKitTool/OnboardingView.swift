//
//  OnboardingView.swift
//  GestaltKitTool
//
//  Shows a multi-step welcome explaining the tool's risks,
//  backup recommendation, and respring behavior. The user
//  must explicitly accept before the main UI is unlocked.
//

import SwiftUI

struct OnboardingView: View {
    /// Called when the user accepts the risk declaration.
    let onAccept: () -> Void

    @State private var step = 0
    @State private var acknowledgedBackup = false
    @State private var acknowledgedRespring = false
    @State private var acknowledgedIrreversible = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Progress dots
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { idx in
                        Circle()
                            .fill(idx == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.top, 12)

                Group {
                    switch step {
                    case 0: welcomeStep
                    case 1: riskStep
                    default: checklistStep
                    }
                }
                .padding(24)
                .frame(maxHeight: .infinity)

                Divider()

                // Bottom navigation bar
                HStack {
                    if step > 0 {
                        Button(String(localized: "Back")) { step -= 1 }
                    }
                    Spacer()
                    if step < 2 {
                        Button(String(localized: "Next")) { step += 1 }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(String(localized: "I Understand & Continue")) { onAccept() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canProceed)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .navigationTitle(String(localized: "Welcome"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(true)
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text(String(localized: "GestaltKitTool"))
                .font(.largeTitle.weight(.bold))

            Text(String(localized: "A utility for browsing and modifying the MobileGestalt plist on supported iOS versions."))
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Label(String(localized: "Toggle system features and flags"), systemImage: "switch.2")
                Label(String(localized: "Browse the sandbox file system"), systemImage: "folder")
                Label(String(localized: "Create and restore backups"), systemImage: "arrow.uturn.backward.circle")
                Label(String(localized: "Apply shared tweak profiles"), systemImage: "square.and.arrow.down.on.square")
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
    }

    // MARK: - Step 1: Risk Declaration

    private var riskStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(String(localized: "Risk Declaration"), systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 12) {
                riskBullet(
                    icon: "cpu",
                    text: String(localized: "This tool modifies system-level plist files that are normally read-only. Incorrect changes may cause system instability.")
                )
                riskBullet(
                    icon: "arrow.uturn.backward",
                    text: String(localized: "A backup is created automatically before each write. You can also create manual backups from the Backups screen.")
                )
                riskBullet(
                    icon: "arrow.clockwise",
                    text: String(localized: "Changes are applied immediately. After writing, the device will respring (restart SpringBoard) for changes to take effect.")
                )
                riskBullet(
                    icon: "person.crop.circle.badge.exclamationmark",
                    text: String(localized: "Some changes (e.g. enabling iPadOS mode) are difficult to reverse and may require restoring from a backup.")
                )
                riskBullet(
                    icon: "lock.shield",
                    text: String(localized: "This tool works via a sandbox escape (bad_query). It does not require a jailbreak, but it relies on specific iOS build vulnerabilities that may be patched in future updates.")
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func riskBullet(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 2: Checklist

    private var checklistStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(String(localized: "Before You Begin"), systemImage: "checkmark.seal.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 16) {
                checklistToggle(
                    isOn: $acknowledgedBackup,
                    text: String(localized: "I understand that I should create a backup before making changes, and that automatic backups are created before each write.")
                )
                checklistToggle(
                    isOn: $acknowledgedRespring,
                    text: String(localized: "I understand that applying changes will respring my device, causing all apps to close temporarily.")
                )
                checklistToggle(
                    isOn: $acknowledgedIrreversible,
                    text: String(localized: "I understand that some changes may be difficult to reverse, and I accept the risks of using this tool.")
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Text(String(localized: "You can revisit this information anytime from Settings → About."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func checklistToggle(isOn: Binding<Bool>, text: String) -> some View {
        Toggle(isOn: isOn) {
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var canProceed: Bool {
        acknowledgedBackup && acknowledgedRespring && acknowledgedIrreversible
    }
}
