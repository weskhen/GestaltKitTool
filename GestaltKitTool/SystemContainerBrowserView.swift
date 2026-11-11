//
//  SystemContainerBrowserView.swift
//  GestaltKitTool
//
//  Lightweight directory browser for a single system container
//  discovered by SystemContainerScanner. Reuses BadQueryFileAccess
//  and PlistViewerView for plist rendering.
//

import SwiftUI

// MARK: - Browser

/// Lightweight directory browser for a container (system or app)
/// discovered by the scanners. Reuses BadQueryFileAccess and
/// PlistViewerView for plist rendering.
struct SystemContainerBrowserView: View {
    /// Minimal info needed to browse any container.
    struct Info {
        let uuid: String
        let fullPath: String
        let ownerBundleID: String
    }

    let info: Info

    init(container: SystemContainer) {
        self.info = Info(
            uuid: container.uuid,
            fullPath: container.fullPath,
            ownerBundleID: container.ownerBundleID
        )
    }

    @State private var entries: [BQFileEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var navigationStack: [String] = []
    @State private var preview: FilePreview?
    @State private var showsPreview = false

    private let fileAccess = BadQueryFileAccess.shared()

    private var currentPath: String {
        navigationStack.last ?? info.fullPath
    }

    var body: some View {
        List {
            if !navigationStack.isEmpty {
                Section {
                    Button {
                        _ = navigationStack.popLast()
                        Task { await load(path: currentPath) }
                    } label: {
                        Label("Up — \((currentPath as NSString).lastPathComponent)", systemImage: "chevron.up.circle")
                    }
                }
            }
            Section {
                if isLoading {
                    HStack { ProgressView(); Text(String(localized: "Loading…")) }
                } else if entries.isEmpty {
                    Text(String(localized: "Empty or unreadable directory."))
                        .foregroundStyle(.secondary)
                }
                ForEach(entries, id: \.fullPath) { entry in
                    Button {
                        handleTap(entry)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .font(.system(.subheadline, design: .monospaced))
                                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.fileSize), countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                Text((currentPath as NSString).lastPathComponent.isEmpty
                     ? info.uuid
                     : (currentPath as NSString).lastPathComponent)
            }
        }
        .navigationTitle(info.ownerBundleID)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    AppPreferencesSummaryView(
                        containerPath: info.fullPath,
                        containerName: info.ownerBundleID
                    )
                } label: {
                    Image(systemName: "list.bullet.rectangle.portrait")
                }
                .accessibilityLabel(String(localized: "Preferences Summary"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SystemContainerAuditView(fullPath: info.fullPath, ownerBundleID: info.ownerBundleID)} label: {
                    Label(String(localized: "Audit"), systemImage: "checkmark.shield")
                }
            }
        }
        .task {
            if entries.isEmpty && navigationStack.isEmpty {
                await load(path: info.fullPath)
            }
        }
        .sheet(isPresented: $showsPreview) {
            if let preview {
                FilePreviewSheet(preview: preview)
            }
        }
        .alert(String(localized: "Error"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func handleTap(_ entry: BQFileEntry) {
        if entry.isDirectory {
            navigationStack.append(entry.fullPath as String)
            Task { await load(path: entry.fullPath as String) }
        } else {
            Task {
                await readPreview(entry)
            }
        }
    }

    private func load(path: String) async {
        isLoading = true
        errorMessage = nil
        let fa = fileAccess
        let result: ([BQFileEntry], String?) = await Task.detached(priority: .userInitiated) {
            var err: NSError?
            let list = fa.listDirectory(atPath: path, error: &err)
            return (list, err?.localizedDescription)
        }.value
        isLoading = false
        entries = result.0
        if result.0.isEmpty, let err = result.1 {
            errorMessage = err
        }
    }

    private func readPreview(_ entry: BQFileEntry) async {
        isLoading = true
        let fa = fileAccess
        let path = entry.fullPath as String
        let result: FilePreview? = await Task.detached(priority: .userInitiated) {
            guard let data = try? fa.readFile(atPath: path) else { return nil }
            return FilePreview(entry: entry, data: data)
        }.value
        isLoading = false
        if let result {
            preview = result
            showsPreview = true
        } else {
            errorMessage = String(localized: "Unable to read file (MAC-blocked or missing).")
        }
    }
}

// MARK: - Activation Credentials (feature B)

struct ActivationCredentialView: View {
    let container: SystemContainer

    @State private var dataArk: FilePreview?
    @State private var activationRecord: FilePreview?
    @State private var selectedSheet: CredentialSheet?
    @State private var isLoading = false
    @State private var loadError: String?

    private let fileAccess = BadQueryFileAccess.shared()

    private var dataArkPath: String {
        (container.fullPath as NSString)
            .appendingPathComponent("Library/internal/data_ark.plist")
    }
    private var activationRecordPath: String {
        (container.fullPath as NSString)
            .appendingPathComponent("Library/activation_records/activation_record.plist")
    }

    var body: some View {
        List {
            Section {
                Label {
                    Text(String(localized: "Full activation state: AccountToken, FairPlay key, device certificates. Handle as sensitive."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                credentialRow(
                    title: "data_ark.plist",
                    subtitle: String(localized: "Activation state & boot session"),
                    preview: dataArk
                )
                credentialRow(
                    title: "activation_record.plist",
                    subtitle: String(localized: "AccountToken, certificates, FairPlay"),
                    preview: activationRecord
                )
            } header: {
                Text(String(localized: "Files"))
            } footer: {
                if isLoading {
                    Text(String(localized: "Loading…"))
                } else if let loadError {
                    Text(loadError).foregroundStyle(.red)
                }
            }

            // Parsed certificate summary when available
            if let record = activationRecord,
               let dict = record.plistDictionary as? [String: Any] {
                Section {
                    ForEach(Self.certificateFields(in: dict), id: \.field) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.field)
                                .font(.system(.subheadline, design: .monospaced))
                            Text(item.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Label(String(localized: "Certificate Summary"), systemImage: "checkmark.seal")
                }
            }
        }
        .navigationTitle(String(localized: "Activation Credentials"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard dataArk == nil && activationRecord == nil else { return }
            await loadAll()
        }
        .sheet(item: $selectedSheet) { sheet in
            NavigationStack {
                PlistViewerView(preview: sheet.preview)
                    .navigationTitle(sheet.preview.entry.name)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func credentialRow(title: String, subtitle: String, preview: FilePreview?) -> some View {
        Button {
            if let preview {
                selectedSheet = CredentialSheet(preview: preview)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(.subheadline, design: .monospaced))
                    if let preview {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(preview.data.count), countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(subtitle)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
        .disabled(preview == nil)
    }

    private func loadAll() async {
        isLoading = true
        loadError = nil
        let fa = fileAccess
        let arkPath = dataArkPath
        let recPath = activationRecordPath

        let loaded: (FilePreview?, FilePreview?) = await Task.detached(priority: .userInitiated) {
            func read(_ path: String) -> FilePreview? {
                guard let data = try? fa.readFile(atPath: path) else { return nil }
                var st = stat()
                let isDir = lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
                let entry = BQFileEntry(
                    name: (path as NSString).lastPathComponent,
                    fullPath: path,
                    isDirectory: isDir,
                    fileSize: Int64(data.count)
                )
                return FilePreview(entry: entry, data: data)
            }
            return (read(arkPath), read(recPath))
        }.value

        dataArk = loaded.0
        activationRecord = loaded.1
        isLoading = false
        if loaded.0 == nil && loaded.1 == nil {
            loadError = String(localized: "Both files unreadable — container layout may differ on this OS.")
        }
    }

    // MARK: Certificate parsing

    /// Fields in activation_record.plist that hold DER certificates.
    private static let certFieldNames = [
        "AccountTokenCertificate", "DeviceCertificate", "UniqueDeviceCertificate"
    ]

    private static func certificateFields(in dict: [String: Any]) -> [(field: String, summary: String)] {
        var results: [(String, String)] = []
        for field in certFieldNames {
            guard let data = dict[field] as? Data else { continue }
            results.append((field, Self.summarizeCertificate(data)))
        }
        return results
    }

    private static func summarizeCertificate(_ data: Data) -> String {
        guard let cert = SecCertificateCreateWithData(nil, data as CFData) else {
            return String(localized: "\(data.count) bytes (not a parsable certificate)")
        }
        var lines: [String] = []
        if let subject = SecCertificateCopySubjectSummary(cert) as String? {
            lines.append("Subject: \(subject)")
        }
        return lines.joined(separator: " · ")
    }
}

/// Identifiable wrapper for the credential sheets.
private struct CredentialSheet: Identifiable {
    let preview: FilePreview
    var id: String { preview.entry.fullPath }
}

// MARK: - Container Audit (feature C)

/// One-shot audit of a system container: recursively lstat/read
/// everything reachable and report readable / blocked / unreadable.
struct SystemContainerAuditView: View {
    let fullPath: String
    let ownerBundleID: String

    init(container: SystemContainer) {
        self.fullPath = container.fullPath
        self.ownerBundleID = container.ownerBundleID
    }

    init(fullPath: String, ownerBundleID: String) {
        self.fullPath = fullPath
        self.ownerBundleID = ownerBundleID
    }

    @State private var report: AuditReport?
    @State private var isRunning = false

    struct AuditReport {
        let scannedCount: Int
        let readable: [String]
        let blocked: [String]
        let plists: [(path: String, size: Int)]
    }

    var body: some View {
        List {
            if isRunning {
                Section {
                    HStack {
                        ProgressView()
                        Text(String(localized: "Auditing container…"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let report {
                Section {
                    LabeledContent("Scanned", value: "\(report.scannedCount)")
                    LabeledContent("Readable", value: "\(report.readable.count)")
                    LabeledContent("Blocked / missing", value: "\(report.blocked.count)")
                } header: {
                    Text(String(localized: "Summary"))
                }
                Section {
                    ForEach(report.readable.sorted(), id: \.self) { path in
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                } header: {
                    Label(String(localized: "Readable files"), systemImage: "checkmark.circle")
                }
                Section {
                    ForEach(report.blocked.sorted(), id: \.self) { path in
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Label(String(localized: "Blocked or missing"), systemImage: "xmark.circle")
                }
                Section {
                    ForEach(report.plists, id: \.path) { item in
                        HStack {
                            Text(item.path)
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Label(String(localized: "Property lists found"), systemImage: "doc.text")
                }
            }
        }
        .navigationTitle(String(localized: "Audit"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard report == nil && !isRunning else { return }
            isRunning = true
            let fa = BadQueryFileAccess.shared()
            let root = fullPath
            let result: AuditReport = await Task.detached(priority: .userInitiated) {
                var readable: [String] = []
                var blocked: [String] = []
                var plists: [(String, Int)] = []
                var scanned = 0

                func walk(_ dir: String, depth: Int) {
                    if depth > 4 { return }
                    var err: NSError?
                    let entries = fa.listDirectory(atPath: dir, error: &err)
                    for e in entries {
                        scanned += 1
                        let p = e.fullPath as String
                        if e.isDirectory {
                            walk(p, depth: depth + 1)
                        } else {
                            if let data = try? fa.readFile(atPath: p) {
                                readable.append(p)
                                if e.name.hasSuffix(".plist") {
                                    plists.append((p, data.count))
                                }
                            } else {
                                blocked.append(p)
                            }
                        }
                    }
                }
                walk(root, depth: 0)
                return AuditReport(
                    scannedCount: scanned,
                    readable: readable,
                    blocked: blocked,
                    plists: plists.map { (path: $0.0, size: $0.1) }
                )
            }.value
            report = result
            isRunning = false
        }
    }
}
