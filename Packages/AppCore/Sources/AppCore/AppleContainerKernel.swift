import Foundation

/// The guest architecture a default kernel is installed for.
public enum AppleKernelArchitecture: String, Sendable, CaseIterable {
    case arm64
    case amd64
}

/// Where `container system kernel set` takes the kernel from.
public enum AppleKernelSource: Sendable, Equatable {
    /// The kernel that the `[kernel]` system properties name (`--recommended`).
    case recommended
    /// A kernel binary on this Mac (`--binary`).
    case binary(path: String)
    /// A tar archive (local path or http(s) URL) and the kernel file inside it
    /// (`--tar` + `--binary`). `digest` (`sha256:<hex>`) is required for a URL.
    case archive(location: String, member: String, digest: String?)
}

/// One `container system kernel set` request.
public struct AppleKernelRequest: Sendable, Equatable {
    public var source: AppleKernelSource
    public var architecture: AppleKernelArchitecture
    /// Overwrite an installed kernel with the same name.
    public var force: Bool

    public init(source: AppleKernelSource, architecture: AppleKernelArchitecture = .arm64, force: Bool = false) {
        self.source = source
        self.architecture = architecture
        self.force = force
    }

    public static let recommended = AppleKernelRequest(source: .recommended, force: true)

    /// The validated `container` arguments. `supportsDigest` is false on CLIs
    /// older than 1.2, which have no `--digest`.
    public func arguments(supportsDigest: Bool = true) throws -> [String] {
        var arguments = ["system", "kernel", "set"]
        switch source {
        case .recommended:
            arguments.append("--recommended")
        case .binary(let path):
            let path = path.trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") else {
                throw AppleSystemError.invalidInput(String(localized: "Choose a kernel file on this Mac.", bundle: .module))
            }
            arguments += ["--arch", architecture.rawValue, "--binary", path]
        case .archive(let location, let member, let digest):
            let location = location.trimmingCharacters(in: .whitespaces)
            let member = member.trimmingCharacters(in: .whitespaces)
            let digest = digest?.trimmingCharacters(in: .whitespaces) ?? ""
            let remote = location.lowercased().hasPrefix("http://") || location.lowercased().hasPrefix("https://")
            guard remote || location.hasPrefix("/") else {
                throw AppleSystemError.invalidInput(String(localized: "Enter an http(s) URL or choose a tar archive on this Mac.", bundle: .module))
            }
            if remote, URL(string: location)?.host == nil {
                throw AppleSystemError.invalidInput(String(localized: "“\(location)” is not a valid URL.", bundle: .module))
            }
            guard !member.isEmpty else {
                throw AppleSystemError.invalidInput(String(localized: "Enter the path of the kernel file inside the archive.", bundle: .module))
            }
            arguments += ["--arch", architecture.rawValue, "--tar", location, "--binary", member]
            if !digest.isEmpty {
                guard supportsDigest else {
                    throw AppleSystemError.invalidInput(String(localized: "This apple/container version cannot verify a digest. Update to 1.2 or later.", bundle: .module))
                }
                guard AppleContainerControl.isValidDigest(digest) else {
                    throw AppleSystemError.invalidInput(String(localized: "The digest must have the form sha256:<64 hex digits>.", bundle: .module))
                }
                arguments += ["--digest", digest]
            } else if remote, supportsDigest {
                throw AppleSystemError.invalidInput(String(localized: "A digest (sha256:…) is required for a remote archive.", bundle: .module))
            }
        }
        if force { arguments.append("--force") }
        return arguments
    }
}

/// The installed default kernel, read from the services' application root.
public struct AppleKernelInfo: Sendable, Equatable {
    public var architecture: AppleKernelArchitecture
    /// The file the `default.kernel-<arch>` link points to, or nil when no
    /// default kernel is installed.
    public var kernelFile: String?

    public var isInstalled: Bool { kernelFile != nil }

    public init(architecture: AppleKernelArchitecture, kernelFile: String?) {
        self.architecture = architecture
        self.kernelFile = kernelFile
    }
}

extension AppleContainerControl {
    // MARK: - Kernel

    /// The apple/container application root when the CLI cannot report one.
    public static var defaultAppRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.container", isDirectory: true)
    }

    /// Whether a default kernel is installed: the services keep it as the
    /// `kernels/default.kernel-<arch>` link under the application root.
    public static func defaultKernel(
        appRoot: URL? = nil,
        architecture: AppleKernelArchitecture = .arm64
    ) -> AppleKernelInfo {
        let root = appRoot ?? defaultAppRoot
        let link = root.appendingPathComponent("kernels/default.kernel-\(architecture.rawValue)")
        let resolved = link.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return AppleKernelInfo(architecture: architecture, kernelFile: nil)
        }
        return AppleKernelInfo(architecture: architecture, kernelFile: resolved.lastPathComponent)
    }

    /// Runs `container system kernel set`, yielding progress lines (download,
    /// unpack, install). The services must be running.
    public static func installKernel(
        _ request: AppleKernelRequest,
        supportsDigest: Bool = true,
        cliOverride: String? = nil
    ) throws -> AsyncThrowingStream<String, Error> {
        streamContainer(try request.arguments(supportsDigest: supportsDigest), cliOverride: cliOverride)
    }

    /// Whether an error message says that no default kernel is installed, so
    /// containers cannot start until one is.
    public static func isMissingKernelError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("default kernel not found")
            || lower.contains("no default kernel")
            || lower.contains("kernel set --recommended")
            || (lower.contains("kernel not found") && lower.contains("kernels/"))
    }

    /// A percentage from a progress line, e.g. `[2/3] Downloading 45% (…)`.
    public static func progressFraction(in line: String) -> Double? {
        guard let match = line.firstMatch(of: /(\d{1,3}(?:\.\d+)?)\s?%/),
              let value = Double(match.1), value <= 100 else { return nil }
        return value / 100
    }

    /// `sha256:` followed by 64 hex digits.
    public static func isValidDigest(_ value: String) -> Bool {
        value.wholeMatch(of: /sha256:[0-9a-fA-F]{64}/) != nil
    }
}
