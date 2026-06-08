import AppKit
import Foundation
import UniformTypeIdentifiers

/// Recognizes Dockerfiles by name and, as a fallback, by content. Drives both
/// the drag-and-drop target and "Open With → Gantry" routing.
enum DockerfileDetector {
    /// Whether `url` looks like a Dockerfile worth offering to build.
    static func isDockerfile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        // `Dockerfile`, `Dockerfile.prod`, `api.dockerfile`, `Containerfile`.
        if name == "dockerfile" || name == "containerfile" { return true }
        if name.hasPrefix("dockerfile.") || name.hasSuffix(".dockerfile") { return true }
        if name.hasPrefix("containerfile.") || name.hasSuffix(".containerfile") { return true }
        // Content sniff for oddly-named files: a leading `FROM`/`# syntax` line.
        return hasDockerfileHeader(url)
    }

    /// Looks for a `FROM` (or BuildKit `# syntax=`) directive in the first few
    /// non-blank lines, the practical signature of a Dockerfile.
    private static func hasDockerfileHeader(_ url: URL) -> Bool {
        guard url.pathExtension.isEmpty || url.pathExtension.lowercased() == "txt",
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        for raw in text.components(separatedBy: .newlines).prefix(40) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("# syntax=") { return true }
            if line.hasPrefix("#") { continue }
            return lower.hasPrefix("from ")
        }
        return false
    }

    /// If `url` is a directory, returns the Dockerfile it contains (preferring a
    /// plain `Dockerfile`). Returns `url` itself when it is already a Dockerfile.
    static func resolveDockerfile(at url: URL) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return nil
        }
        if !isDir.boolValue {
            return isDockerfile(url) ? url : nil
        }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )) ?? []
        if let exact = children.first(where: { $0.lastPathComponent.lowercased() == "dockerfile" }) {
            return exact
        }
        return children.first(where: isDockerfile)
    }
}

/// Buffers Dockerfiles opened before the main window is ready (cold launch via
/// Finder), mirroring `PendingComposeOpens`.
@MainActor
enum PendingDockerfileOpens {
    private(set) static var urls: [URL] = []

    static func add(_ url: URL) { urls.append(url) }

    static func drain() -> [URL] {
        defer { urls.removeAll() }
        return urls
    }
}
