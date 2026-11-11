//
//  DeviceDashboardView.swift
//  GestaltKitTool
//
//  UI for: activation credential backup export, device identity
//  dashboard, and keychain reachability probe.
//

import SwiftUI

// MARK: - Backup Export Card (inside Activation Health)

struct ActivationBackupCard: View {
    @StateObject private var exporter = ActivationBackupExporter()
    let container: SystemContainer?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task { await exporter.export(from: container) }
                } label: {
                    Label(String(localized: "Backup Activation Credentials"),
                          systemImage: "externaldrive.badge.timemachine")
                        .font(.subheadline.weight(.medium))
                }
                .disabled(exporter.isExporting)

                Text(String(localized: "Exports data_ark.plist and activation_record.plist as a JSON file. Keep it private — it contains your device's activation identity."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if exporter.isExporting {
                    ProgressView()
                }
                if let err = exporter.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
                if let url = exporter.exportURL {
                    ShareLink(item: url) {
                        Label(String(localized: "Share Backup File"), systemImage: "square.and.arrow.up")
                            .font(.subheadline)
                    }
                }
            }
        } footer: {
            Text(String(localized: "Backup is stored temporarily on-device. Export it to a safe location."))
        }
    }
}

// MARK: - Device Dashboard (standalone page)

struct DeviceDashboardView: View {
    @StateObject private var model = DeviceDashboardModel()

    var body: some View {
        List {
            if model.isRunning && model.rows.isEmpty {
                Section {
                    HStack {
                        ProgressView()
                        Text(String(localized: "Loading…"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let err = model.errorMessage {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            if !model.rows.isEmpty {
                Section {
                    ForEach(model.rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(row.displayValue)
                                .font(.system(.subheadline, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text(String(localized: "Device Identity (MobileGestalt)"))
                } footer: {
                    Text(String(localized: "Values as currently stored in the MobileGestalt cache — after any tweaks you applied."))
                }
            }
        }
        .navigationTitle(String(localized: "Device Dashboard"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.run()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isRunning)
            }
        }
        .task {
            if model.rows.isEmpty && model.errorMessage == nil {
                model.run()
            }
        }
    }
}

// MARK: - Keychain Probe (standalone page)

struct KeychainProbeView: View {
    @StateObject private var model = KeychainProbeModel()

    var body: some View {
        List {
            Section {
                Text(String(localized: "Tests which keychain classes the sandbox lets this app enumerate. This is a read-only reachability probe — no credentials are displayed."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.isRunning && model.results.isEmpty {
                Section { ProgressView() }
            }
            Section {
                ForEach(model.results) { r in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: r.isReadable
                              ? "lock.open.circle.fill"
                              : r.isReachableButEmpty
                              ? "circle.dashed"
                              : "lock.circle.fill")
                            .foregroundStyle(
                                r.isReadable ? .orange
                                : r.isReachableButEmpty ? .secondary
                                : .red
                            )
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.scope)
                                .font(.subheadline.weight(.medium))
                            Text(r.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            } header: {
                Text(String(localized: "Results"))
            } footer: {
                Text(String(localized: "A sandboxed app can normally only see its own keychain items. Any wider visibility would indicate a keychain access entitlement flaw."))
            }
        }
        .navigationTitle(String(localized: "Keychain Probe"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.run()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isRunning)
            }
        }
        .task {
            if model.results.isEmpty {
                model.run()
            }
        }
    }
}
