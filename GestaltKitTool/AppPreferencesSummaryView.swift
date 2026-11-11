//
//  AppPreferencesSummaryView.swift
//  GestaltKitTool
//
//  Flattened, searchable view of every preference plist in a container.
//

import SwiftUI

struct AppPreferencesSummaryView: View {
    let containerPath: String
    let containerName: String
    @StateObject private var summarizer = AppPreferencesSummarizer()
    @State private var searchText = ""

    private var filtered: [AppPreferenceEntry] {
        guard !searchText.isEmpty else { return summarizer.entries }
        let q = searchText.lowercased()
        return summarizer.entries.filter {
            $0.key.lowercased().contains(q) || $0.value.lowercased().contains(q)
        }
    }

    var body: some View {
        List {
            if summarizer.isRunning {
                Section {
                    HStack {
                        ProgressView()
                        Text(String(localized: "Reading preference plists…"))
                    }
                }
            }
            if let err = summarizer.errorText {
                Section {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !summarizer.entries.isEmpty {
                Section {
                    Text(String(format: String(localized: "%d keys from %d files"), summarizer.entries.count, summarizer.filesRead))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(filtered) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.key)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                            Text(entry.value.isEmpty ? "—" : entry.value)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 1)
                    }
                } header: {
                    Text(String(localized: "Keys"))
                } footer: {
                    Text(String(localized: "All preference values under this container's Preferences directory, flattened for search."))
                }
            }
        }
        .searchable(text: $searchText, prompt: String(localized: "Key or value"))
        .navigationTitle(String(localized: "Preferences Summary"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if summarizer.entries.isEmpty && !summarizer.isRunning {
                summarizer.summarize(containerPath: containerPath)
            }
        }
    }
}
