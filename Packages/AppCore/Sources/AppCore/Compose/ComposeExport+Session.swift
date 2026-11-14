import Foundation
import DockerKit

extension HostSession {
    /// Inspects each container and its image for "Export as Compose". The
    /// containers keep the given order. Throws when the host is down or a
    /// container cannot be inspected; a missing image is not an error.
    public func composeExportSources(for containerIDs: [String]) async throws -> [ComposeExportSource] {
        guard let client else {
            throw DockerError.connectionFailed(String(localized: "Not connected", bundle: .module))
        }
        var sources: [ComposeExportSource] = []
        for id in containerIDs {
            let body = try await client.rawInspectContainer(id: id)
            var image: Data?
            for reference in Self.imageReferences(inContainerInspect: body) {
                if let data = try? await client.rawInspectImage(id: reference) {
                    image = data
                    break
                }
            }
            sources.append(ComposeExportSource(
                containerInspect: body,
                imageInspect: image,
                isAppleContainer: host.isAppleContainer,
                isRemoteHost: host.isSSH
            ))
        }
        return sources
    }

    /// The image ID first (exact), then the reference of the container config.
    nonisolated static func imageReferences(inContainerInspect body: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [] }
        let config = root["Config"] as? [String: Any] ?? [:]
        let candidates = [root["Image"] as? String, config["Image"] as? String].compactMap { $0 }
        var result: [String] = []
        for candidate in candidates where !candidate.isEmpty && !result.contains(candidate) {
            result.append(candidate)
        }
        return result
    }
}
