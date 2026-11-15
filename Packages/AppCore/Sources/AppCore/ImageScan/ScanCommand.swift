import Foundation

/// What a scanner run writes.
public enum ScanOutput: Sendable, Equatable {
    /// The JSON vulnerability report.
    case report
    /// An SBOM file.
    case sbom(SBOMFormat)
}

/// The command lines of `specs/011-image-scan/contracts/scanner-commands.md`.
public enum ScanCommand {
    /// Large images take longer than the Trivy default of 5 minutes.
    static let trivyTimeout = "30m"

    /// The arguments for one scanner run that writes to `outputPath`.
    public static func arguments(
        _ kind: ScannerKind,
        source: ScanSource,
        output: ScanOutput,
        outputPath: String
    ) -> [String] {
        switch kind {
        case .trivy: trivyArguments(source: source, output: output, outputPath: outputPath)
        case .grype: grypeArguments(source: source, output: output, outputPath: outputPath)
        }
    }

    private static func trivyArguments(source: ScanSource, output: ScanOutput, outputPath: String) -> [String] {
        var args = ["image", "--quiet", "--timeout", trivyTimeout]
        switch output {
        case .report: args += ["--scanners", "vuln", "--format", "json"]
        case .sbom(.cycloneDX): args += ["--format", "cyclonedx"]
        case .sbom(.spdx): args += ["--format", "spdx-json"]
        }
        args += ["--output", outputPath]
        switch source {
        case .ociLayout(let path), .dockerArchive(let path):
            args += ["--input", path]
        case .registry(let reference, let platform):
            args += ["--image-src", "remote"]
            if let platform { args += ["--platform", platform] }
            args.append(reference)
        }
        return args
    }

    private static func grypeArguments(source: ScanSource, output: ScanOutput, outputPath: String) -> [String] {
        var args: [String]
        switch source {
        case .ociLayout(let path): args = ["oci-dir:\(path)"]
        case .dockerArchive(let path): args = ["docker-archive:\(path)"]
        case .registry(let reference, let platform):
            args = ["registry:\(reference)"]
            if let platform { args += ["--platform", platform] }
        }
        let format = switch output {
        case .report: "json"
        // Grype has no SPDX output; the model offers only CycloneDX for it.
        case .sbom: "cyclonedx-json"
        }
        return args + ["-q", "-o", format, "--file", outputPath]
    }

    /// `container image save` for the scan export.
    public static func appleSaveArguments(reference: String, platform: String?, to path: String) -> [String] {
        var args = ["image", "save"]
        if let platform { args += ["--platform", platform] }
        return args + ["--output", path, reference]
    }

    /// The `tar` binary of macOS.
    public static let tarPath = "/usr/bin/tar"

    /// Unpacks an OCI tar into a folder that exists.
    public static func unpackArguments(archive: String, into folder: String) -> [String] {
        ["-xf", archive, "-C", folder]
    }
}
