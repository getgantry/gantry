import Foundation
import DockerKit

/// Finds the `kubectl` binary and installs it with Homebrew on request.
public enum KubectlTooling {
    /// The Homebrew formula (`brew install kubectl`).
    public static let formula = "kubernetes-cli"

    /// The install command that the empty state shows.
    public static let installCommand = "brew install kubectl"

    public static let installPageURL = URL(string: "https://kubernetes.io/docs/tasks/tools/install-kubectl-macos/")!

    /// TEST SEAM and escape hatch: a full path to `kubectl`.
    public static let cliEnvOverride = "GANTRY_KUBECTL"

    /// The places that installers use, before the PATH of the app.
    static let wellKnownDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "~/.rd/bin",
        "~/.local/bin",
        "/Applications/Docker.app/Contents/Resources/bin",
        "/usr/bin",
    ]

    /// The `kubectl` path: the override, the known directories, then PATH.
    public static func cliPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let override = environment[cliEnvOverride], !override.isEmpty {
            return isExecutable(override) ? override : nil
        }
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        for directory in wellKnownDirectories + pathDirectories {
            let expanded = directory.hasPrefix("~") ? home + directory.dropFirst() : directory
            guard !expanded.isEmpty, seen.insert(expanded).inserted else { continue }
            let candidate = (expanded as NSString).appendingPathComponent("kubectl")
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// Installs kubectl with Homebrew and sends each output line to `progress`.
    public static func install(progress: @escaping @Sendable (String) -> Void) async throws {
        guard let brew = ContainerTooling.brewPath() else { throw ContainerToolingError.homebrewMissing }
        let lines = KubeLineSplitter()
        let child = ChildProcess(
            executable: brew,
            arguments: ["install", formula],
            environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"],
            mergeOutput: true
        )
        let exit: ChildProcessExit = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try child.start(output: { chunk in
                        if case .stdout(let data) = chunk { lines.feed(data).forEach(progress) }
                    }, completion: { exit in
                        lines.flush().forEach(progress)
                        continuation.resume(returning: exit)
                    })
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            child.terminate()
        }
        try Task.checkCancellation()
        guard exit.succeeded else { throw ContainerToolingError.commandFailed(Int(exit.status)) }
    }
}

/// Splits a byte stream into lines. Thread-safe, for child process callbacks.
final class KubeLineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    /// Returns the complete lines in `data` plus the bytes held from before.
    func feed(_ data: Data) -> [String] {
        lock.withLock {
            buffer.append(data)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                var line = buffer[buffer.startIndex..<newline]
                if line.last == 0x0D { line = line.dropLast() }
                lines.append(String(decoding: line, as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
    }

    /// The last line without a newline, if any.
    func flush() -> [String] {
        lock.withLock {
            defer { buffer.removeAll() }
            return buffer.isEmpty ? [] : [String(decoding: buffer, as: UTF8.self)]
        }
    }
}
