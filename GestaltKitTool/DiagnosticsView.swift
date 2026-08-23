//
//  DiagnosticsView.swift
//  GestaltKitTool
//
//  Diagnostics panel — tests bad_query availability, sandbox lease
//  acquisition, container discovery, and file read operations.
//

import Combine
import SwiftUI

struct DiagnosticsView: View {
    @StateObject private var model = DiagnosticsModel()

    var body: some View {
        List {
            Section {
                Button {
                    model.runAll()
                } label: {
                    HStack {
                        Image(systemName: "stethoscope")
                        Text("Run All Diagnostics")
                    }
                }
                .disabled(model.isRunning)

                Button {
                    model.runFlagProbe()
                } label: {
                    HStack {
                        Image(systemName: "flask")
                        Text(String(localized: "Probe Flags (Find RW)"))
                    }
                }
                .disabled(model.isRunning)
            } footer: {
                Text(String(localized: "Run All tests bad_query availability, sandbox lease, container discovery, and file read operations. Probe Flags enumerates flag combinations to find one that grants read-write access (diagnostic only, results in Console.app filter [GKTL-ObjC])."))
            }

            Section("Results") {
                ForEach(model.results) { result in
                    DiagnosticResultRow(result: result)
                }
            }

            if !model.log.isEmpty {
                Section("Log") {
                    Text(model.log)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Diagnostic Result Row

private struct DiagnosticResultRow: View {
    let result: DiagnosticResult

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.status.icon)
                .foregroundStyle(result.status.color)
                .font(.body)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.name)
                    .font(.body)
                    .foregroundStyle(.primary)

                if let detail = result.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Text(result.status.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(result.status.color)
        }
    }
}

// MARK: - Diagnostics Model

@MainActor
final class DiagnosticsModel: ObservableObject {
    @Published var results: [DiagnosticResult] = []
    @Published var isRunning = false
    @Published var log = ""

    private let fileAccess = BadQueryFileAccess.shared()

    func runFlagProbe() {
        guard !isRunning else { return }
        isRunning = true
        results = []
        log = ""

        let gestaltPath = "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"

        Task.detached(priority: .userInitiated) {
            BadQueryProbeFlags(gestaltPath)

            await MainActor.run {
                self.log = String(localized: "Flag probe complete. Check Console.app (filter [GKTL-ObjC]) for results.\nLook for lines with canWrite=1 — that flag value grants read-write access.")
                self.isRunning = false
            }
        }
    }

    func runAll() {
        guard !isRunning else { return }
        isRunning = true
        results = []
        log = ""

        NotificationCenter.default.post(
            name: .init("GKTCancelBackgroundExplorerTasks"),
            object: nil
        )

        let fileAccess = self.fileAccess

        // for cooperative cancellation and better backpressure.
        Task.detached(priority: .userInitiated) {
            // MARK: Test 1 — bad_query Availability
            let r1: DiagnosticResult = {
                let available = BadQueryBridgeAvailable()
                return DiagnosticResult(
                    name: "bad_query Availability",
                    status: available ? .pass : .fail,
                    detail: available
                        ? "bad_query bridge is loaded and available."
                        : "bad_query bridge is NOT available."
                )
            }()

            // MARK: Shared lease acquisition
            //
            // All sandbox-granted tests (2, 4, 6) operate on the same
            // MobileGestalt plist file. Instead of acquiring 3 separate
            // ContainerManager leases (3 × 1-3 s XPC round-trips),
            // we acquire ONE lease and share it across all tests.
            // This cuts total diagnostic time by ~60% on devices where
            // ContainerManager XPC is slow (iOS 27 beta).
            let gestaltPath = "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"
            let cacheDir = "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches"

            var leaseError: NSString?
            let sharedLease = BadQueryLease(forPath: gestaltPath, error: &leaseError)
            let leaseActive = sharedLease?.isActive ?? false
            defer { sharedLease?.invalidate() }

            // MARK: Test 2 — Sandbox Lease Acquisition (shared)
            let r2: DiagnosticResult = {
                if leaseActive {
                    return DiagnosticResult(
                        name: "Sandbox Lease Acquisition",
                        status: .pass,
                        detail: String(localized: "Lease acquired for file:\n\(gestaltPath)")
                    )
                } else {
                    let errMsg = leaseError as? String ?? String(localized: "unknown error")
                    // Enrich the error with iOS version-specific guidance.
                    let osVersion = ProcessInfo.processInfo.operatingSystemVersion
                    let build = GestaltAccess.currentOSBuild()
                    var enriched = String(localized: "Failed to acquire lease: \(errMsg)")
                    if osVersion.majorVersion == 26 && osVersion.minorVersion == 0 {
                        enriched += "\n\n" + String(localized: "[ iOS 26.0.x detected (build \(build)) ] bad_query's ContainerManager query was accepted but the kernel refused to issue a sandbox extension. This is a known symptom on early iOS 26.0 builds where the sandbox policy differs from iOS 27. Possible causes:\n  1. The MobileGestalt cache plist has not been generated yet — try respringing once, then rerun diagnostics.\n  2. The bad_query exploit parameters (class=13, part=3, flags=0x8000000000) may need adjustment for this specific build.\n  3. Apple may have partially patched bad_query in this build.\n\nCheck the device console (Console.app, filter [GKTL-ObjC]) for detailed per-stage logs showing exactly where the lease acquisition failed (lstat / create / getSingleResult / copySandboxToken / consume).")
                    }
                    return DiagnosticResult(
                        name: "Sandbox Lease Acquisition",
                        status: .fail,
                        detail: enriched
                    )
                }
            }()

            // MARK: Test 3 — Container Discovery (fsgetpath, no lease needed)
            let r3: DiagnosticResult = {
                let appDataRoot = "/var/mobile/Containers/Data/Application"
                var listError: NSError?
                let entries = fileAccess.listDirectory(atPath: appDataRoot, error: &listError)
                let count = entries.filter { $0.isDirectory }.count
                let msg: String
                let status: DiagnosticStatus
                if let listError {
                    msg = "Container discovery failed: \(listError.localizedDescription)"
                    status = .fail
                } else if count == 0 {
                    msg = "No app containers found."
                    status = .warn
                } else {
                    msg = "Discovered \(count) app data containers."
                    status = .pass
                }
                return DiagnosticResult(name: "Container Discovery", status: status, detail: msg)
            }()

            // MARK: Test 4 — File Read Test (uses shared lease, no extra XPC)
            //
            // The shared lease is already active for gestaltPath, so we
            // can read the file directly without acquiring another
            // lease via fileAccess.readFile. This eliminates the 2nd
            // ContainerManager XPC round-trip entirely.
            let r4: DiagnosticResult = {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: gestaltPath))
                    return DiagnosticResult(
                        name: "File Read Test",
                        status: data.count > 0 ? .pass : .warn,
                        detail: "Read \(data.count) bytes from MobileGestalt plist."
                    )
                } catch {
                    return DiagnosticResult(
                        name: "File Read Test",
                        status: .fail,
                        detail: "Cannot read MobileGestalt plist: \(error.localizedDescription)"
                    )
                }
            }()

            // MARK: Test 5 — Directory Listing Test (fsgetpath, no lease needed)
            let r5: DiagnosticResult = {
                let testPath = "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches"
                var listError: NSError?
                let entries = fileAccess.listDirectory(atPath: testPath, error: &listError)
                let msg: String
                let status: DiagnosticStatus
                if let listError {
                    msg = "Directory listing failed: \(listError.localizedDescription)"
                    status = .fail
                } else if entries.isEmpty {
                    msg = "Directory is empty or inaccessible."
                    status = .warn
                } else {
                    msg = "Listed \(entries.count) entries in MobileGestalt cache dir."
                    status = .pass
                }
                return DiagnosticResult(name: "Directory Listing Test", status: status, detail: msg)
            }()

            // MARK: Test 6 — MobileGestalt Write Test (uses shared lease)
            //
            // Mirrors saveGestalt:'s exact open() flags (O_WRONLY|O_CLOEXEC|O_NOFOLLOW):
            //   1. Open gestaltPath — if it fails, saveGestalt: will fail too.
            //   2. If open succeeds, close immediately (non-destructive).
            //   3. Optional O_CREAT probe is informational-only and never flips Pass/Fail.
            let r6: DiagnosticResult = {
                guard leaseActive else {
                    let detail = leaseError as? String ?? "unknown bad_query error"
                    return DiagnosticResult(
                        name: "MobileGestalt Write Test",
                        status: .fail,
                        detail: "No active sandbox lease — skipping write probe (\(detail))."
                    )
                }

                return gestaltPath.withCString { gestaltFsRep in
                    // MARK: - Phase A (truth): open REAL plist like saveGestalt: does
                    let gestaltFd = open(gestaltFsRep,
                                         O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
                    guard gestaltFd >= 0 else {
                        let err = errno
                        let hint: String
                        switch err {
                        case EACCES:
                            hint = "\nHint (DAC ownership mismatch): The MobileGestalt cache plist is not writable by our uid (\(geteuid())). This is a real failure — saveGestalt: will return EACCES too, even with an active bad_query lease."
                        case EPERM:
                            hint = "\nHint (EPERM despite lease): MAC-level policy or the immutable flag blocks O_WRONLY on the plist. saveGestalt: will also fail with EPERM."
                        case ENOENT:
                            hint = "\nHint (ENOENT): The MobileGestalt plist does not exist at the expected path. This can happen on a freshly-booted device before MobileGestalt has written its cache; try respringing once then rerun diagnostics."
                        case EBADF:
                            hint = "\nHint (EBADF from open): The sandbox extension for this path was rejected or has been revoked. Try rerunning diagnostics to reacquire the lease."
                        default:
                            hint = ""
                        }
                        return DiagnosticResult(
                            name: "MobileGestalt Write Test",
                            status: .fail,
                            detail: "saveGestalt: mirror probe — cannot open MobileGestalt plist for writing (errno=\(err): \(String(cString: strerror(err)))). \(hint)"
                        )
                    }
                    // Close immediately — no mutation. A successful
                    // open() with saveGestalt:'s exact flags is the
                    // strongest possible signal that saveGestalt: will
                    // also be able to open the fd and proceed.
                    let closeResult = close(gestaltFd)
                    let closeErrno = errno

                    // MARK: - Phase B (informational only): O_CREAT probe
                    // Never downgrades Phase A's Pass; only adds an optional warning note.
                    let tmpFile = cacheDir + "/.gestaltkit_tool_writeprobe.tmp"
                    var probeMsg: String? = nil
                    var probeStatus: DiagnosticStatus = .pass
                    tmpFile.withCString { probeFsRep in
                        defer { unlink(probeFsRep) }
                        let pfd = open(probeFsRep,
                                       O_WRONLY | O_CREAT | O_TRUNC | O_EXCL,
                                       0o644)
                        if pfd >= 0 {
                            // Phase B: informational O_CREAT probe with strict return checks.
                            let sig: [UInt8] = [0x57, 0x45, 0x53, 0x4B]
                            let written: Int = sig.withUnsafeBytes { p in
                                guard let b = p.baseAddress else { return -1 }
                                return write(pfd, b, 4)
                            }
                            let fsyncRet = fsync(pfd)
                            let fsyncErr = fsyncRet != 0 ? errno : 0
                            let probeClose = close(pfd)
                            let probeCloseErr = probeClose != 0 ? errno : 0
                            _ = unlink(probeFsRep)
                            var notes: [String] = []
                            if written < 4 { notes.append("write=\(written)") }
                            if fsyncRet != 0 { notes.append("fsync errno=\(fsyncErr)") }
                            if probeClose != 0 { notes.append("close errno=\(probeCloseErr)") }
                            if notes.isEmpty {
                                probeMsg = "Directory O_CREAT probe: pass."
                            } else {
                                probeMsg = "Directory O_CREAT probe: pass (\(notes.joined(separator: "; ")))."
                                probeStatus = .warn
                            }
                        } else {
                            let err = errno
                            // Phase B EPERM/EACCES are expected — MAC policy denies O_CREAT.
                            // Phase A already proved saveGestalt: works, so Phase B stays .pass.
                            probeStatus = .pass
                            switch err {
                            case EPERM:
                                probeMsg = "Directory O_CREAT probe: EPERM (expected on most iOS versions — MAC/immutable flag denies creation inside cache dir. Not a problem for saveGestalt:, which overwrites the existing plist)."
                            case EACCES:
                                probeMsg = "Directory O_CREAT probe: EACCES (DAC ownership mismatch on cache dir). saveGestalt: may still work (it does not O_CREAT)."
                            case EEXIST:
                                probeMsg = "Directory O_CREAT probe: EEXIST (stale probe file). Probe was cleaned up by defer/unlink."
                            default:
                                probeMsg = "Directory O_CREAT probe: errno=\(err) (\(String(cString: strerror(err))))."
                                probeStatus = .warn
                            }
                        }
                    }

                    // MARK: - Compose final result
                    var finalStatus: DiagnosticStatus = .pass
                    var detail = "saveGestalt: mirror probe — opened MobileGestalt.plist O_WRONLY (matches saveGestalt: open flags). saveGestalt: should succeed. \(probeMsg ?? "")"
                    if closeResult != 0 {
                        finalStatus = .warn
                        detail = "saveGestalt: mirror probe — opened MobileGestalt.plist O_WRONLY OK, but close() returned errno=\(closeErrno). Non-fatal, but indicates flushing issues. \(probeMsg ?? "")"
                    }
                    // Phase B (O_CREAT probe) is informational-only.
                    // Phase A success = saveGestalt: will work → .pass.
                    return DiagnosticResult(
                        name: "MobileGestalt Write Test",
                        status: finalStatus,
                        detail: detail
                    )
                }
            }()

            let allResults = [r1, r2, r3, r4, r5, r6]
            let logText = allResults.map { $0.detail ?? "" }.joined(separator: "\n")

            Task { @MainActor [weak self] in
                self?.results = allResults
                self?.log = logText + "\n" + String(localized: "Diagnostics complete.")
                self?.isRunning = false
            }
        }
    }
}

// MARK: - Diagnostic Status

enum DiagnosticStatus {
    case pass, warn, fail

    var icon: String {
        switch self {
        case .pass: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .pass: .green
        case .warn: .orange
        case .fail: .red
        }
    }

    var label: String {
        switch self {
        case .pass: String(localized: "Pass")
        case .warn: String(localized: "Warning")
        case .fail: String(localized: "Fail")
        }
    }
}

// MARK: - Diagnostic Result Model

struct DiagnosticResult: Identifiable {
    let id = UUID()
    let name: String
    let status: DiagnosticStatus
    let detail: String?
}
