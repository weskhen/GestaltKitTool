//
//  ActivationReport.swift
//  GestaltKitTool
//
//  Activation health check built on the verified worse_query escape.
//  Reads data_ark.plist + activation_record.plist from the
//  mobileactivationd system container and produces a structured
//  report: activation state, brick state, certificate chain.
//

import Combine
import Foundation

// MARK: - Report Model

/// Overall activation health verdict.
enum ActivationVerdict: String {
    case activatedHealthy = "Activated — Healthy"
    case activatedIssues = "Activated — Issues Found"
    case notActivated = "Not Activated"
    case bricked = "Brick State"
    case unknown = "Unknown"

    var isOK: Bool { self == .activatedHealthy }
}

/// A parsed DER/PEM certificate from the activation record.
struct CertificateSummary: Identifiable {
    let field: String
    let subject: String?
    let issuer: String?
    let serial: String?
    let notValidBefore: Date?
    let notValidAfter: Date?
    let isValidPEM: Bool
    let byteCount: Int
    var id: String { field }

    /// nil = no end date known; false = expired or not yet valid.
    var isDateValid: Bool? {
        guard let after = notValidAfter else { return nil }
        let now = Date()
        if let before = notValidBefore, now < before { return false }
        return now <= after
    }
}

/// One key finding in the health check.
struct ActivationFinding: Identifiable {
    enum Level { case ok, warn, fail, info }
    let level: Level
    let title: String
    let detail: String
    var id: String { title }
}

/// Full report assembled from both plists.
struct ActivationReport {
    let verdict: ActivationVerdict
    let findings: [ActivationFinding]
    let dataArkRaw: [String: Any]?
    let activationRecordRaw: [String: Any]?
    let certificates: [CertificateSummary]

    // MARK: Field accessors (data_ark.plist keys, verified on device)

    var activationState: String? {
        dataArkRaw?["-ActivationState"] as? String
    }
    var brickState: Int? {
        dataArkRaw?["-BrickState"] as? Int
    }
    var activationExpired: Int? {
        dataArkRaw?["-ActivationExpired"] as? Int
    }
    var enforceValidRecord: Int? {
        dataArkRaw?["-EnforceValidActivationRecord"] as? Int
    }
    var productVersion: String? {
        dataArkRaw?["-ProductVersion"] as? String
    }
    var buildVersion: String? {
        dataArkRaw?["-BuildVersion"] as? String
    }
    var lastActivatedBuild: String? {
        dataArkRaw?["-LastActivated"] as? String
    }
}

// MARK: - Checker

/// Performs the health check. All file I/O goes through
/// BadQueryFileAccess (worse_query lease).
@MainActor
final class ActivationChecker: ObservableObject {

    @Published private(set) var report: ActivationReport?
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?

    private let fileAccess = BadQueryFileAccess.shared()

    func run(container: SystemContainer?) {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil

        let fa = fileAccess
        // Resolve the mobileactivationd container: either the one
        // handed in (from the scanner) or fall back to a fresh scan.
        Task.detached(priority: .userInitiated) { [weak self] in
            var target = container
            if target == nil {
                target = await Self.findActivationContainer(fa)
            }
            guard let target else {
                await MainActor.run { [weak self] in
                    self?.errorMessage = String(localized: "mobileactivationd container not found — scan System Containers first.")
                    self?.isRunning = false
                }
                return
            }

            let arkPath = (target.fullPath as NSString)
                .appendingPathComponent("Library/internal/data_ark.plist")
            let recPath = (target.fullPath as NSString)
                .appendingPathComponent("Library/activation_records/activation_record.plist")

            var arkDict: [String: Any]? = nil
            var recDict: [String: Any]? = nil
            var loadError: String? = nil

            if let data = try? fa.readFile(atPath: arkPath) {
                arkDict = (try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil)) as? [String: Any]
            }
            if let data = try? fa.readFile(atPath: recPath) {
                recDict = (try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil)) as? [String: Any]
            }

            if arkDict == nil && recDict == nil {
                loadError = String(localized: "Both activation plists unreadable on this device.")
            }

            let report = Self.analyze(ark: arkDict, record: recDict)

            await MainActor.run {
                self?.report = report
                self?.errorMessage = loadError
                self?.isRunning = false
            }
        }
    }

    private nonisolated static func findActivationContainer(
        _ fa: BadQueryFileAccess
    ) async -> SystemContainer? {
        // Shared lookup (ContainerMetadata.findSystemContainer).
        guard let hit = ContainerMetadata.findSystemContainer(
            fileAccess: fa, ownerBundleId: "com.apple.mobileactivationd"
        ) else { return nil }
        return SystemContainer(
            uuid: hit.uuid,
            fullPath: hit.fullPath,
            ownerBundleID: "com.apple.mobileactivationd")
    }

    // MARK: Analysis (pure)

    private nonisolated static func analyze(
        ark: [String: Any]?,
        record: [String: Any]?
    ) -> ActivationReport {
        var findings: [ActivationFinding] = []
        var certs: [CertificateSummary] = []
        var verdict: ActivationVerdict = .unknown

        // — data_ark.plist checks —
        if let ark {
            if let state = ark["-ActivationState"] as? String {
                let ok = state == "Activated"
                findings.append(.init(
                    level: ok ? .ok : .fail,
                    title: String(localized: "Activation State"),
                    detail: state
                ))
            }
            if let brick = ark["-BrickState"] as? Int {
                let ok = brick == 0
                findings.append(.init(
                    level: ok ? .ok : .fail,
                    title: String(localized: "Brick State"),
                    detail: brick == 0
                        ? String(localized: "Not bricked")
                        : String(format: String(localized: "BRICKED (%lld)"), Int64(brick))
                ))
            }
            if let expired = ark["-ActivationExpired"] as? Int {
                let ok = expired == 0
                findings.append(.init(
                    level: ok ? .ok : .warn,
                    title: String(localized: "Activation Expired Flag"),
                    detail: expired == 0
                        ? String(localized: "Not expired")
                        : String(localized: "Marked expired")
                ))
            }
            if let enforce = ark["-EnforceValidActivationRecord"] as? Int {
                findings.append(.init(
                    level: .info,
                    title: String(localized: "Enforce Valid Record"),
                    detail: enforce == 1
                        ? String(localized: "Enforced (activation record must be valid)")
                        : String(localized: "Not enforced")
                ))
            }
            if let version = ark["-ProductVersion"] as? String {
                findings.append(.init(
                    level: .info,
                    title: String(localized: "Product Version (at activation)"),
                    detail: version
                ))
            }
            if let lastBuild = ark["-LastActivated"] as? String {
                findings.append(.init(
                    level: .info,
                    title: String(localized: "Last Activated Build"),
                    detail: lastBuild
                ))
            }
            if let bootUUID = ark["-BootSessionUUID"] as? String {
                findings.append(.init(
                    level: .info,
                    title: String(localized: "Boot Session UUID"),
                    detail: bootUUID
                ))
            }
        }

        // — activation_record.plist certificate chain —
        if let record {
            for field in ["AccountTokenCertificate", "DeviceCertificate",
                          "UniqueDeviceCertificate"] {
                if let data = record[field] as? Data {
                    certs.append(Self.parseCertificate(field: field, data: data))
                }
            }
            if let token = record["AccountToken"] as? Data {
                findings.append(.init(
                    level: .ok,
                    title: String(localized: "Account Token"),
                    detail: String(format: String(localized: "Present (%lld bytes)"), Int64(token.count))
                ))
                // AccountToken is a JSON payload (starts with '{').
                if let json = try? JSONSerialization.jsonObject(
                    with: token) as? [String: Any] {
                    if let laptop = json.keys.first(where: { $0.lowercased().contains("laptop") }) {
                        findings.append(.init(
                            level: .info,
                            title: String(localized: "Token Content"),
                            detail: String(describing: json[laptop]).prefix(120).description
                        ))
                    }
                }
            }
            if let fp = record["FairPlayKeyData"] as? Data {
                findings.append(.init(
                    level: .ok,
                    title: String(localized: "FairPlay Key Data"),
                    detail: String(format: String(localized: "Present (%lld bytes, CONTAINER header)"), Int64(fp.count))
                ))
            }
            if let unbrick = record["unbrick"] as? Int {
                findings.append(.init(
                    level: unbrick == 1 ? .ok : .warn,
                    title: String(localized: "Unbrick Flag (record)"),
                    detail: unbrick == 1
                        ? String(localized: "Record allows unbrick")
                        : String(localized: "Record does NOT unbrick")
                ))
            }
            if let version = record["LDActivationVersion"] as? Int {
                findings.append(.init(
                    level: .info,
                    title: String(localized: "Activation Protocol Version"),
                    detail: "LDActivationVersion = \(version)"
                ))
            }
            if let reg = record["RegulatoryInfo"] as? Data,
               let json = try? JSONSerialization.jsonObject(with: reg) as? [String: Any] {
                let summary = json.map { "\($0.key)=\($0.value)" }
                    .sorted().joined(separator: ", ")
                findings.append(.init(
                    level: .info,
                    title: String(localized: "Regulatory Info"),
                    detail: String(summary.prefix(120))
                ))
            }
        }

        // — verdict —
        let stateOK = (ark?["-ActivationState"] as? String) == "Activated"
        let brickOK = (ark?["-BrickState"] as? Int) == 0
        if let brick = ark?["-BrickState"] as? Int, brick != 0 {
            verdict = .bricked
        } else if stateOK && brickOK {
            let certIssues = certs.filter { c in
                c.isValidPEM == false || (c.isDateValid == false)
            }.count
            verdict = certIssues > 0 ? .activatedIssues : .activatedHealthy
        } else if stateOK == false && ark != nil {
            verdict = .notActivated
        }

        return ActivationReport(
            verdict: verdict,
            findings: findings,
            dataArkRaw: ark,
            activationRecordRaw: record,
            certificates: certs
        )
    }

    private nonisolated static func parseCertificate(
        field: String, data: Data
    ) -> CertificateSummary {
        // Certificates in activation_record are PEM text.
        let pem = String(data: data, encoding: .utf8) ?? ""
        let hasPEMHeader = pem.contains("-----BEGIN CERT")
        var subject: String? = nil
        var issuer: String? = nil
        var serial: String? = nil
        var notBefore: Date? = nil
        var notAfter: Date? = nil

        if let cert = Self.certificateFromPEM(pem) {
            subject = SecCertificateCopySubjectSummary(cert) as String?
            serial = Self.serialNumber(of: cert)
            if let dates = Self.validityDates(of: cert) {
                notBefore = dates.0
                notAfter = dates.1
            }
            if let issuerName = SecCertificateCopyNormalizedIssuerSequence(cert) {
                issuer = Self.firstReadableOID(issuerName as CFData)
            }
        }
        return CertificateSummary(
            field: field,
            subject: subject,
            issuer: issuer,
            serial: serial,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            isValidPEM: hasPEMHeader,
            byteCount: data.count
        )
    }

    /// Decode PEM → DER → SecCertificate.
    private nonisolated static func certificateFromPEM(
        _ pem: String
    ) -> SecCertificate? {
        guard let begin = pem.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = pem.range(of: "-----END CERTIFICATE-----") else {
            return nil
        }
        let body = pem[begin.upperBound..<end.lowerBound]
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard let der = Data(base64Encoded: String(body)) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    private nonisolated static func serialNumber(
        of cert: SecCertificate
    ) -> String? {
        guard let der = SecCertificateCopySerialNumber(cert) as Data? else {
            return nil
        }
        return der.map { String(format: "%02x", $0) }.joined()
    }

    /// NotBefore/NotAfter are not directly exposed on iOS —
    /// report unknown rather than guessing.
    private nonisolated static func validityDates(
        of cert: SecCertificate
    ) -> (Date?, Date?)? {
        nil
    }

    private nonisolated static func firstReadableOID(
        _ data: CFData
    ) -> String? {
        // Best-effort: extract printable ASCII runs for a human
        // readable issuer hint.
        let bytes = data as Data
        var runs: [String] = []
        var current = ""
        for b in bytes {
            if (32...126).contains(b) {
                current.append(Character(UnicodeScalar(b)))
            } else {
                if current.count >= 4 { runs.append(current) }
                current = ""
            }
        }
        if current.count >= 4 { runs.append(current) }
        return runs.first
    }
}
