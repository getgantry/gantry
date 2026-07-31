import Foundation
import DockerKit

extension HostSession {
    /// Recreates a container with a new (or cleared) apple/container DNS domain,
    /// preserving its image, command, environment, published port bindings, volume
    /// binds, restart policy and labels. The DNS domain is immutable on a live
    /// container — apple/container only accepts `--dns-domain` at create time — so
    /// changing it means removing the old container and creating a fresh one.
    ///
    /// Named volumes and bind mounts persist (they live outside the container);
    /// the container's own writable layer does not, exactly like `docker rm`
    /// followed by `docker run`. Returns the new container id.
    @discardableResult
    public func recreateWithDomain(
        container: ContainerSummary,
        details: ContainerDetails,
        domain: String?
    ) async throws -> String {
        let config = details.config
        let image = (config.image?.isEmpty == false) ? config.image! : container.image

        // Re-publish the same host port bindings: ["80/tcp": "8080"].
        var portMap: [String: String] = [:]
        for port in container.ports {
            if let published = port.publicPort, published > 0 {
                portMap["\(port.privatePort)/\(port.type)"] = String(published)
            }
        }

        let trimmedDomain = domain?.trimmingCharacters(in: .whitespaces) ?? ""
        let hasDomain = !trimmedDomain.isEmpty

        // Preserve existing labels, re-stamping (or clearing) our DNS marker so
        // the address view reflects the new domain.
        var labels = config.labels ?? [:]
        if hasDomain {
            labels[Self.dnsDomainLabelKey] = trimmedDomain
        } else {
            labels.removeValue(forKey: Self.dnsDomainLabelKey)
        }

        // apple/container's inspect reports neither the custom kernel nor its
        // boot arguments, so the labels stamped at create time are the only
        // record of them — without this the container would come back on the
        // stock kernel.
        let appleOptions = ContainerCreateRequest.AppleOptions(labels: labels)

        let request = ContainerCreateRequest(
            image: image,
            cmd: config.cmd,
            env: config.env ?? [],
            ports: portMap,
            binds: details.hostConfig.binds ?? [],
            restartPolicy: details.hostConfig.restartPolicy?.name ?? "no",
            tty: config.tty,
            labels: labels,
            autoRemove: details.hostConfig.autoRemove ?? false,
            domainname: hasDomain ? trimmedDomain : nil,
            appleOptions: appleOptions,
            name: container.displayName
        )

        // Force-remove the old container first so its name is free to reuse.
        _ = await perform(.remove(force: true), on: container.id)
        let newID = try await createAndRun(request)
        // Clear any stale negative DNS cache so the new name.domain resolves now.
        if hasDomain { await AppleContainerControl.flushDNSCache() }
        return newID
    }

    /// A friendly, unique container name derived from an image reference — e.g.
    /// `docker.io/library/nginx:alpine` → `nginx`, disambiguated to `nginx-2` if
    /// taken. Auto-naming makes a container's DNS name (`name.domain`) meaningful
    /// instead of a random Docker-assigned one.
    public func uniqueContainerName(forImage image: String) -> String {
        let repo = image.split(separator: "/").last.map(String.init) ?? image
        let base = repo.split(separator: ":").first.map(String.init) ?? repo
        return uniqueContainerName(base: base.isEmpty ? "app" : base)
    }

    /// Returns `base` when no current container already uses it, else the first
    /// free `base-N`. Keeps auto-assigned names unique across the host.
    public func uniqueContainerName(base: String) -> String {
        let taken = Set(containers.map(\.displayName))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}
