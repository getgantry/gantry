import Foundation

/// The vulnerability scanners Gantry can run. Neither is bundled or installed
/// by Gantry: the user installs them, and a missing scanner only shows help.
public enum ScannerKind: String, CaseIterable, Sendable, Identifiable {
    case trivy
    case grype

    public var id: String { rawValue }

    /// The product name. Not localized.
    public var displayName: String {
        switch self {
        case .trivy: "Trivy"
        case .grype: "Grype"
        }
    }

    /// The Homebrew command that installs the scanner, shown as help.
    public var installCommand: String { "brew install \(rawValue)" }

    /// The install page of the project.
    public var installPageURL: URL {
        switch self {
        case .trivy: URL(string: "https://trivy.dev/latest/getting-started/installation/")!
        case .grype: URL(string: "https://github.com/anchore/grype#installation")!
        }
    }

    /// The oldest version whose flags Gantry uses (see the command contract).
    public var minimumVersion: String {
        switch self {
        case .trivy: "0.50.0"
        case .grype: "0.74.0"
        }
    }

    /// Environment variable that points at a binary outside the usual folders.
    public var environmentOverride: String {
        switch self {
        case .trivy: "GANTRY_TRIVY"
        case .grype: "GANTRY_GRYPE"
        }
    }

    /// Arguments that print the version.
    public var versionArguments: [String] {
        switch self {
        case .trivy: ["--version"]
        case .grype: ["version"]
        }
    }

    /// The SBOM formats the scanner writes. Grype has no SPDX output.
    public var sbomFormats: [SBOMFormat] {
        switch self {
        case .trivy: [.cycloneDX, .spdx]
        case .grype: [.cycloneDX]
        }
    }
}

/// A file format for a software bill of materials.
public enum SBOMFormat: String, CaseIterable, Sendable, Identifiable {
    case cycloneDX
    case spdx

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cycloneDX: "CycloneDX"
        case .spdx: "SPDX"
        }
    }

    /// The suggested file name suffix.
    public var fileSuffix: String {
        switch self {
        case .cycloneDX: ".cdx.json"
        case .spdx: ".spdx.json"
        }
    }
}

/// A scanner found on this Mac.
public struct InstalledScanner: Sendable, Equatable, Identifiable {
    public var kind: ScannerKind
    public var path: String
    /// The version, or nil when the binary printed none that Gantry can read.
    public var version: String?

    public var id: ScannerKind { kind }

    public init(kind: ScannerKind, path: String, version: String?) {
        self.kind = kind
        self.path = path
        self.version = version
    }

    /// An unknown version is allowed, as for the `container` CLI.
    public var isSupported: Bool {
        guard let version else { return true }
        return ContainerTooling.isVersion(version, atLeast: kind.minimumVersion)
    }
}

/// Finds the scanner binaries and reads their versions.
public enum ScannerLocator {
    /// The Homebrew folders. A GUI app gets a short `PATH`, so they are
    /// searched also when `PATH` does not name them.
    public static let fallbackFolders = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The binary of `kind`: the environment override, then the folders of
    /// `PATH`, then the Homebrew folders.
    public static func locate(
        _ kind: ScannerKind,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let override = environment[kind.environmentOverride]?.trimmingCharacters(in: .whitespaces),
           !override.isEmpty, isExecutable(override) {
            return override
        }
        let pathFolders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        for folder in pathFolders + fallbackFolders where !folder.isEmpty && seen.insert(folder).inserted {
            let candidate = (folder as NSString).appendingPathComponent(kind.rawValue)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// Reads `x.y.z` from a `Version:` line (`trivy --version`, `grype version`).
    public static func parseVersion(_ output: String) -> String? {
        if let match = output.firstMatch(of: #/Version:\s*v?(\d+\.\d+\.\d+)/#) {
            return String(match.1)
        }
        return nil
    }

    /// The installed scanners, Trivy first.
    public static func detect(
        runner: ScanProcessRunning,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) async -> [InstalledScanner] {
        var found: [InstalledScanner] = []
        for kind in ScannerKind.allCases {
            guard let path = locate(kind, environment: environment, isExecutable: isExecutable) else { continue }
            let output = try? await runner.run(path, kind.versionArguments)
            let text = output.map { String(decoding: $0.stdout + $0.stderr, as: UTF8.self) } ?? ""
            found.append(InstalledScanner(kind: kind, path: path, version: parseVersion(text)))
        }
        return found
    }
}
