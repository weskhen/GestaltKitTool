//
//  ActivationReportView.swift
//  GestaltKitTool
//
//  Activation health report: verdict and key findings first,
//  technical detail collapsed below.
//

import SwiftUI

struct ActivationReportView: View {
    @StateObject private var checker = ActivationChecker()
    let container: SystemContainer?

    @State private var showsTechnical = false

    var body: some View {
        List {
            if checker.isRunning {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(String(localized: "Reading activation records…"))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let report = checker.report {
                heroSection(report)
                badgesSection(report)
                meaningSection(report)
                technicalSection(report)
                ActivationBackupCard(container: container)
            }

            if let err = checker.errorMessage {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
        .navigationTitle(String(localized: "Activation Health"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    checker.run(container: container)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(checker.isRunning)
            }
        }
        .task {
            if checker.report == nil {
                checker.run(container: container)
            }
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroSection(_ report: ActivationReport) -> some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: report.verdict.isOK
                      ? "checkmark.seal.fill"
                      : (report.verdict == .bricked
                         ? "exclamationmark.octagon.fill"
                         : "exclamationmark.triangle.fill"))
                    .font(.system(size: 52))
                    .foregroundStyle(verdictColor(report.verdict))
                Text(report.verdict.humanTitle)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(report.verdict.humanSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .listRowBackground(report.verdict.isOK ? Color.green.opacity(0.08) : Color.orange.opacity(0.08))
    }

    // MARK: - Badges

    @ViewBuilder
    private func badgesSection(_ report: ActivationReport) -> some View {
        Section {
            HStack(spacing: 8) {
                badge(
                    title: String(localized: "Activated"),
                    ok: report.activationState == "Activated"
                )
                badge(
                    title: String(localized: "Certificates"),
                    ok: !report.certificates.isEmpty
                        && report.certificates.allSatisfy { $0.isValidPEM }
                )
                badge(
                    title: String(localized: "Not Bricked"),
                    ok: report.brickState == 0
                )
                badge(
                    title: String(localized: "Not Expired"),
                    ok: report.activationExpired == 0
                )
            }
            .padding(.vertical, 4)
        }
    }

    private func badge(title: String, ok: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - What this means

    @ViewBuilder
    private func meaningSection(_ report: ActivationReport) -> some View {
        Section {
            ForEach(report.verdict.meaningLines) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: item.level))
                        .foregroundStyle(color(for: item.level))
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(.medium))
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        } header: {
            Text(String(localized: "What this means"))
        }
    }

    // MARK: - Technical

    @ViewBuilder
    private func technicalSection(_ report: ActivationReport) -> some View {
        Section {
            DisclosureGroup(isExpanded: $showsTechnical) {
                ForEach(report.findings) { f in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(for: f.level))
                            .foregroundStyle(color(for: f.level))
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.title).font(.subheadline.weight(.medium))
                            Text(f.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                ForEach(report.certificates) { cert in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cert.field)
                            .font(.system(.subheadline, design: .monospaced).weight(.medium))
                        if let subject = cert.subject {
                            Label(subject, systemImage: "person.crop.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let serial = cert.serial {
                            Text("Serial: \(serial)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Text(ByteCountFormatter.string(fromByteCount: Int64(cert.byteCount), countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                }
            } label: {
                Label(String(localized: "Technical Details"),
                      systemImage: "wrench.and.screwdriver")
                    .font(.subheadline.weight(.medium))
            }
        } footer: {
            Text(String(localized: "Raw fields read via worse_query from com.apple.mobileactivationd."))
        }
    }

    private func icon(for level: ActivationFinding.Level) -> String {
        switch level {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.circle.fill"
        case .info: return "info.circle"
        }
    }

    private func color(for level: ActivationFinding.Level) -> Color {
        switch level {
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .red
        case .info: return .blue
        }
    }

    private func verdictColor(_ v: ActivationVerdict) -> Color {
        switch v {
        case .activatedHealthy: return .green
        case .activatedIssues, .notActivated: return .orange
        case .bricked: return .red
        case .unknown: return .gray
        }
    }
}

// MARK: - Verdict human strings

extension ActivationVerdict {
    /// Large headline, localized.
    var humanTitle: String {
        switch self {
        case .activatedHealthy: return String(localized: "Device Activated & Healthy")
        case .activatedIssues: return String(localized: "Activated — Issues Found")
        case .notActivated: return String(localized: "Not Activated")
        case .bricked: return String(localized: "Brick State")
        case .unknown: return String(localized: "Unknown")
        }
    }

    /// One-sentence plain-language summary.
    var humanSummary: String {
        switch self {
        case .activatedHealthy:
            return String(localized: "Activation record complete, certificate chain valid. This device is fully usable.")
        case .activatedIssues:
            return String(localized: "Device is activated but some checks reported issues — review the technical details.")
        case .notActivated:
            return String(localized: "This device has not completed activation. Most features will be unavailable until activated.")
        case .bricked:
            return String(localized: "This device is marked bricked in its activation data. It cannot be used until restored.")
        case .unknown:
            return String(localized: "Activation state could not be determined from the activation records.")
        }
    }

    /// Plain-language bullet points shown under "What this means".
    var meaningLines: [ActivationFinding] {
        switch self {
        case .activatedHealthy:
            return [
                .init(level: .ok, title: String(localized: "All features available"), detail: String(localized: "Calls, iMessage, App Store and iCloud work normally.")),
                .init(level: .ok, title: String(localized: "Not a demo or locked unit"), detail: String(localized: "The activation record matches this device and is fully signed.")),
                .init(level: .ok, title: String(localized: "Safe to buy or keep using"), detail: String(localized: "No brick markers or expired-activation flags were found.")),
            ]
        case .activatedIssues:
            return [
                .init(level: .warn, title: String(localized: "Review certificate chain"), detail: String(localized: "One or more certificates in the activation record could not be parsed or look abnormal.")),
                .init(level: .info, title: String(localized: "Device may still work"), detail: String(localized: "Issues found are advisory — the device boots and reports itself as activated.")),
            ]
        case .notActivated:
            return [
                .init(level: .fail, title: String(localized: "Activation required"), detail: String(localized: "Connect to Wi-Fi or iTunes to complete activation before use.")),
            ]
        case .bricked:
            return [
                .init(level: .fail, title: String(localized: "Device is disabled"), detail: String(localized: "The activation data contains a brick marker. A full restore via computer is required.")),
            ]
        case .unknown:
            return [
                .init(level: .info, title: String(localized: "Records unreadable"), detail: String(localized: "The activation plists could not be read on this device. Try rescanning.")),
            ]
        }
    }
}
