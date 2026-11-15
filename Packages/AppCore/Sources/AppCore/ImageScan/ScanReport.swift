import Foundation

/// The severity of a finding, from the most to the least severe.
public enum VulnerabilitySeverity: String, CaseIterable, Sendable, Comparable, Identifiable {
    case critical
    case high
    case medium
    case low
    case negligible
    case unknown

    public var id: String { rawValue }

    /// Case-insensitive: Trivy writes `HIGH`, Grype writes `High`.
    public init(parsing text: String?) {
        self = VulnerabilitySeverity(rawValue: (text ?? "").lowercased()) ?? .unknown
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let order = allCases
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }

    public var localizedName: String {
        switch self {
        case .critical: String(localized: "Critical", bundle: .module, comment: "Vulnerability severity")
        case .high: String(localized: "High", bundle: .module, comment: "Vulnerability severity")
        case .medium: String(localized: "Medium", bundle: .module, comment: "Vulnerability severity")
        case .low: String(localized: "Low", bundle: .module, comment: "Vulnerability severity")
        case .negligible: String(localized: "Negligible", bundle: .module, comment: "Vulnerability severity")
        case .unknown: String(localized: "Unknown", bundle: .module, comment: "Vulnerability severity")
        }
    }
}

/// Whether the package has a fixed version.
public enum FixState: String, Sendable, Equatable {
    case fixed
    case notFixed
    case wontFix
    case unknown

    /// Trivy `Status`: `fixed`, `affected`, `will_not_fix`, `fix_deferred`,
    /// `end_of_life`, `under_investigation`, `unknown`.
    static func trivy(_ status: String?, fixedVersions: [String]) -> FixState {
        switch status?.lowercased() {
        case "fixed": return .fixed
        case "will_not_fix", "end_of_life": return .wontFix
        case "affected", "fix_deferred", "under_investigation": return .notFixed
        default: return fixedVersions.isEmpty ? .unknown : .fixed
        }
    }

    /// Grype `fix.state`: `fixed`, `not-fixed`, `wont-fix`, `unknown`.
    static func grype(_ state: String?, fixedVersions: [String]) -> FixState {
        switch state?.lowercased() {
        case "fixed": return .fixed
        case "not-fixed": return .notFixed
        case "wont-fix": return .wontFix
        default: return fixedVersions.isEmpty ? .unknown : .fixed
        }
    }
}

/// One vulnerability in one package.
public struct VulnerabilityFinding: Sendable, Equatable, Identifiable {
    /// Row identity, unique in the report: the same ID can hit two packages.
    public var id: Int
    public var vulnerabilityID: String
    public var severity: VulnerabilitySeverity
    public var packageName: String
    public var packageType: String
    public var installedVersion: String
    public var fixedVersions: [String]
    public var fixState: FixState
    public var title: String
    public var url: URL?

    public init(
        id: Int, vulnerabilityID: String, severity: VulnerabilitySeverity, packageName: String,
        packageType: String = "", installedVersion: String, fixedVersions: [String] = [],
        fixState: FixState = .unknown, title: String = "", url: URL? = nil
    ) {
        self.id = id
        self.vulnerabilityID = vulnerabilityID
        self.severity = severity
        self.packageName = packageName
        self.packageType = packageType
        self.installedVersion = installedVersion
        self.fixedVersions = fixedVersions
        self.fixState = fixState
        self.title = title
        self.url = url
    }

    /// The fixed versions for display, or a short state text.
    public var fixedDisplay: String {
        if !fixedVersions.isEmpty { return fixedVersions.joined(separator: ", ") }
        switch fixState {
        case .wontFix: return String(localized: "Won’t fix", bundle: .module, comment: "A vulnerability the vendor will not fix")
        default: return String(localized: "No fix", bundle: .module, comment: "No fixed version of the package exists")
        }
    }
}

/// The parsed result of one scan.
public struct ScanReport: Sendable, Equatable {
    public struct Group: Sendable, Equatable, Identifiable {
        public var severity: VulnerabilitySeverity
        public var findings: [VulnerabilityFinding]
        public var id: VulnerabilitySeverity { severity }

        public init(severity: VulnerabilitySeverity, findings: [VulnerabilityFinding]) {
            self.severity = severity
            self.findings = findings
        }
    }

    public var scanner: ScannerKind
    public var scannerVersion: String?
    public var findings: [VulnerabilityFinding]

    public init(scanner: ScannerKind, scannerVersion: String?, findings: [VulnerabilityFinding]) {
        self.scanner = scanner
        self.scannerVersion = scannerVersion
        self.findings = findings
    }

    public var total: Int { findings.count }

    public func count(of severity: VulnerabilitySeverity) -> Int {
        findings.reduce(0) { $0 + ($1.severity == severity ? 1 : 0) }
    }

    /// The groups that have findings, Critical first, sorted by package then ID.
    public var groups: [Group] {
        let bySeverity = Dictionary(grouping: findings, by: \.severity)
        return VulnerabilitySeverity.allCases.compactMap { severity in
            guard let items = bySeverity[severity], !items.isEmpty else { return nil }
            let sorted = items.sorted {
                ($0.packageName, $0.vulnerabilityID, $0.id) < ($1.packageName, $1.vulnerabilityID, $1.id)
            }
            return Group(severity: severity, findings: sorted)
        }
    }
}

/// The parse failed: the scanner wrote no report that Gantry can read.
public struct ScanReportError: LocalizedError, Sendable, Equatable {
    public var scanner: ScannerKind
    public init(scanner: ScannerKind) { self.scanner = scanner }
    public var errorDescription: String? {
        String(localized: "Gantry could not read the report of \(scanner.displayName).", bundle: .module)
    }
}

/// Makes an advisory link when the scanner gives none.
public enum VulnerabilityLink {
    public static func url(id: String, toolURL: String?) -> URL? {
        if let toolURL, toolURL.hasPrefix("https://"), let url = URL(string: toolURL) { return url }
        let upper = id.uppercased()
        if upper.hasPrefix("CVE-") {
            return URL(string: "https://www.cve.org/CVERecord?id=\(upper)")
        }
        if upper.hasPrefix("GHSA-") {
            return URL(string: "https://github.com/advisories/\(id)")
        }
        return nil
    }
}

/// Fixed versions as a list: Trivy writes `1.2.3, 1.3.0`.
private func splitVersions(_ text: String?) -> [String] {
    (text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// Parses `trivy image --format json` (schema version 2).
public enum TrivyReportParser {
    private struct Report: Decodable {
        var Trivy: Tool?
        var Results: [Result]?
    }
    private struct Tool: Decodable { var Version: String? }
    private struct Result: Decodable {
        var `Type`: String?
        var Vulnerabilities: [Vulnerability]?
    }
    private struct Vulnerability: Decodable {
        var VulnerabilityID: String
        var PkgName: String?
        var InstalledVersion: String?
        var FixedVersion: String?
        var Status: String?
        var Severity: String?
        var Title: String?
        var PrimaryURL: String?
    }

    public static func parse(_ data: Data) throws -> ScanReport {
        guard let report = try? JSONDecoder().decode(Report.self, from: data) else {
            throw ScanReportError(scanner: .trivy)
        }
        var findings: [VulnerabilityFinding] = []
        for result in report.Results ?? [] {
            for item in result.Vulnerabilities ?? [] {
                let fixed = splitVersions(item.FixedVersion)
                findings.append(VulnerabilityFinding(
                    id: findings.count,
                    vulnerabilityID: item.VulnerabilityID,
                    severity: VulnerabilitySeverity(parsing: item.Severity),
                    packageName: item.PkgName ?? "",
                    packageType: result.Type ?? "",
                    installedVersion: item.InstalledVersion ?? "",
                    fixedVersions: fixed,
                    fixState: FixState.trivy(item.Status, fixedVersions: fixed),
                    title: item.Title ?? "",
                    url: VulnerabilityLink.url(id: item.VulnerabilityID, toolURL: item.PrimaryURL)
                ))
            }
        }
        return ScanReport(scanner: .trivy, scannerVersion: report.Trivy?.Version, findings: findings)
    }
}

/// Parses `grype -o json`.
public enum GrypeReportParser {
    private struct Report: Decodable {
        var matches: [Match]?
        var descriptor: Descriptor?
    }
    private struct Descriptor: Decodable { var version: String? }
    private struct Match: Decodable {
        var vulnerability: Vulnerability
        var relatedVulnerabilities: [Related]?
        var artifact: Artifact
    }
    private struct Related: Decodable { var description: String? }
    private struct Vulnerability: Decodable {
        var id: String
        var severity: String?
        var dataSource: String?
        var description: String?
        var fix: Fix?
    }
    private struct Fix: Decodable {
        var versions: [String]?
        var state: String?
    }
    private struct Artifact: Decodable {
        var name: String?
        var version: String?
        var type: String?
    }

    public static func parse(_ data: Data) throws -> ScanReport {
        guard let report = try? JSONDecoder().decode(Report.self, from: data), report.matches != nil else {
            throw ScanReportError(scanner: .grype)
        }
        let findings = (report.matches ?? []).enumerated().map { index, match in
            let fixed = match.vulnerability.fix?.versions ?? []
            return VulnerabilityFinding(
                id: index,
                vulnerabilityID: match.vulnerability.id,
                severity: VulnerabilitySeverity(parsing: match.vulnerability.severity),
                packageName: match.artifact.name ?? "",
                packageType: match.artifact.type ?? "",
                installedVersion: match.artifact.version ?? "",
                fixedVersions: fixed,
                fixState: FixState.grype(match.vulnerability.fix?.state, fixedVersions: fixed),
                title: firstLine(match.vulnerability.description ?? match.relatedVulnerabilities?.first(where: { $0.description != nil })?.description),
                url: VulnerabilityLink.url(id: match.vulnerability.id, toolURL: match.vulnerability.dataSource)
            )
        }
        return ScanReport(scanner: .grype, scannerVersion: report.descriptor?.version, findings: findings)
    }

    /// Grype has no title. The description is often only on the related
    /// (NVD) record of a distro match.
    private static func firstLine(_ text: String?) -> String {
        let line = (text ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }
}
