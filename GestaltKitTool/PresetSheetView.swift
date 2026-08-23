import SwiftUI

// MARK: - Preset Sheet

struct PresetSheet: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsSavePresetDialog = false
    @State private var newPresetName = ""
    @State private var userPresets: [TweakPreset] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Built-in Presets") {
                    ForEach(TweakPreset.builtIn) { preset in
                        Button {
                            viewModel.loadPreset(preset)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.caption)
                                VStack(alignment: .leading) {
                                    Text(preset.name)
                                        .foregroundStyle(.primary)
                                    Text(verbatim: String(format: String(localized: "%d tweaks"), preset.tweaks.count))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !userPresets.isEmpty {
                    Section("My Presets") {
                        ForEach(userPresets) { preset in
                            HStack {
                                Button {
                                    viewModel.loadPreset(preset)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Image(systemName: "person.crop.circle")
                                            .foregroundStyle(.blue)
                                            .font(.caption)
                                        VStack(alignment: .leading) {
                                            Text(preset.name)
                                                .foregroundStyle(.primary)
                                            Text(verbatim: String(format: String(localized: "%d tweaks"), preset.tweaks.count))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Button(role: .destructive) {
                                    viewModel.deletePreset(preset)
                                    userPresets = PresetStore.loadUserPresets()
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showsSavePresetDialog = true
                    } label: {
                        Label("Save Current as Preset", systemImage: "plus.circle.fill")
                    }
                    .disabled(viewModel.selectedTweaks.isEmpty
                              && viewModel.dynamicIslandSubtype == nil
                              && !viewModel.changesModelName
                              && !viewModel.stagesAIRegion)
                }
            }
            .navigationTitle("Presets")
            .onAppear {
                userPresets = PresetStore.loadUserPresets()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(String(localized: "Save Preset"), isPresented: $showsSavePresetDialog) {
                TextField(String(localized: "Preset Name"), text: $newPresetName)
                Button(String(localized: "Save")) {
                    let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    viewModel.savePreset(name: name)
                    userPresets = PresetStore.loadUserPresets()
                    newPresetName = ""
                }
                Button(String(localized: "Cancel"), role: .cancel) { newPresetName = "" }
            } message: {
                Text(String(localized: "Save the current tweak selection, Dynamic Island subtype, model name, and AI Region setting as a reusable preset."))
            }
        }
    }
}

// MARK: - Status Report Share
struct StatusReportShareView: View {
    @Environment(\.dismiss) private var dismiss
    let report: String

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(report)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .navigationTitle("Status Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: report)
                }
            }
        }
    }
}
