import Foundation
import DockerKit

extension ContainerRecipe {
    /// Label that records the apple/container DNS domain; matches the one
    /// Quick Run and recreate use.
    public static let dnsDomainLabelKey = "com.gantry.dns-domain"

    var trimmedImage: String { image.trimmingCharacters(in: .whitespaces) }

    var portEntries: [ContainerForm.PortEntry] {
        ports.map { ContainerForm.PortEntry(host: $0.host, container: $0.container, proto: $0.proto) }
    }

    /// The create request for this recipe. `name` is the resolved container
    /// name (nil lets the runtime pick one). On a Docker host the apple-only
    /// fields are left out; on an apple host the restart policy is left out,
    /// because the CLI has none. ``hostWarnings(isAppleHost:)`` tells the user.
    public func createRequest(
        name: String?,
        isAppleHost: Bool,
        kernelArgsSupported: Bool = true
    ) -> ContainerCreateRequest {
        let domain = isAppleHost ? dnsDomain.trimmingCharacters(in: .whitespaces) : ""
        var allLabels: [String: String] = [:]
        for label in labels where !label.key.trimmingCharacters(in: .whitespaces).isEmpty {
            allLabels[label.key.trimmingCharacters(in: .whitespaces)] = label.value
        }
        if !domain.isEmpty { allLabels[Self.dnsDomainLabelKey] = domain }
        let appleOptions = isAppleHost ? makeAppleOptions(kernelArgsSupported: kernelArgsSupported) : nil
        // Inspect reports no kernel options, so labels keep them for a recreate.
        allLabels.merge(appleOptions?.labels ?? [:]) { _, new in new }

        let commandWords = command
        let trimmedEntrypoint = entrypoint.trimmingCharacters(in: .whitespaces)
        var request = ContainerCreateRequest(
            image: trimmedImage,
            cmd: commandWords.isEmpty ? nil : commandWords,
            entrypoint: trimmedEntrypoint.isEmpty ? nil : [trimmedEntrypoint],
            domainname: domain.isEmpty ? nil : domain,
            env: env.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }.map { "\($0.key)=\($0.value)" },
            exposedPorts: nil,
            labels: allLabels,
            tty: tty,
            workingDir: nonEmpty(workdir),
            hostConfig: makeHostConfig(isAppleHost: isAppleHost),
            networkingConfig: makeNetworkingConfig(isAppleHost: isAppleHost),
            appleOptions: appleOptions,
            name: name
        )
        let bindings = request.hostConfig?.portBindings ?? [:]
        if !bindings.isEmpty {
            request.exposedPorts = Dictionary(uniqueKeysWithValues: bindings.keys.map { ($0, .init()) })
        }
        request.user = nonEmpty(user)
        request.openStdin = interactive ? true : nil
        return request
    }

    private func nonEmpty(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private func makeAppleOptions(kernelArgsSupported: Bool) -> ContainerCreateRequest.AppleOptions {
        let args = kernelArgsSupported
            ? kernelArgs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : []
        return ContainerCreateRequest.AppleOptions(kernel: nonEmpty(kernel), kernelArgs: args)
    }

    /// Port bindings keyed by `80/tcp`; the first row for a container port
    /// wins, as in ``ContainerForm/portMap(_:requireHost:)``.
    func portBindings() -> [String: [ContainerCreateRequest.PortBinding]] {
        var result: [String: [ContainerCreateRequest.PortBinding]] = [:]
        for port in ports {
            let entry = ContainerForm.PortEntry(host: port.host, container: port.container, proto: port.proto)
            guard !entry.trimmedContainer.isEmpty, result[entry.key] == nil else { continue }
            let ip = port.hostIP.trimmingCharacters(in: .whitespaces)
            result[entry.key] = [.init(hostIP: ip.isEmpty ? nil : ip, hostPort: entry.trimmedHost)]
        }
        return result
    }

    private func makeHostConfig(isAppleHost: Bool) -> ContainerCreateRequest.HostConfig {
        let binds = volumes
            .filter { !$0.source.trimmingCharacters(in: .whitespaces).isEmpty && !$0.target.isEmpty }
            .map(\.bind)
        let policy = restartPolicy.trimmingCharacters(in: .whitespaces)
        let bindings = portBindings()
        var config = ContainerCreateRequest.HostConfig(
            binds: binds.isEmpty ? nil : binds,
            portBindings: bindings.isEmpty ? nil : bindings,
            restartPolicy: (isAppleHost || policy.isEmpty || policy == "no") ? nil : .init(name: policy),
            memory: Self.memoryBytes(memory),
            nanoCPUs: Self.nanoCPUs(cpus),
            autoRemove: autoRemove ? true : nil
        )
        let net = network.trimmingCharacters(in: .whitespaces)
        if !isAppleHost, !Self.isDefaultNetwork(net) {
            config.networkMode = net
        }
        return config
    }

    private func makeNetworkingConfig(isAppleHost: Bool) -> ContainerCreateRequest.NetworkingConfig? {
        let net = network.trimmingCharacters(in: .whitespaces)
        guard !Self.isDefaultNetwork(net), !Self.dockerNetworkModes.contains(net),
              !net.hasPrefix("container:") else { return nil }
        return .init(endpointsConfig: [net: .init()])
    }

    // MARK: - Host warnings

    /// Values this host cannot use, in plain words. The create still goes
    /// ahead without them.
    public func hostWarnings(isAppleHost: Bool) -> [String] {
        isAppleHost ? appleWarnings() : dockerWarnings()
    }

    private func appleWarnings() -> [String] {
        var warnings: [String] = []
        let policy = restartPolicy.trimmingCharacters(in: .whitespaces)
        if !policy.isEmpty, policy != "no" {
            warnings.append(String(localized: "apple/container has no restart policies. The restart policy “\(policy)” is not used.", bundle: .module))
        }
        if let nano = Self.nanoCPUs(cpus), nano % 1_000_000_000 != 0 {
            let whole = max(nano / 1_000_000_000, 1)
            warnings.append(String(localized: "apple/container uses whole CPUs. The container gets \(whole) CPU.", bundle: .module))
        }
        let net = network.trimmingCharacters(in: .whitespaces)
        if Self.dockerNetworkModes.contains(net) || net.hasPrefix("container:") {
            warnings.append(String(localized: "apple/container does not support the network mode “\(net)”. The default network is used.", bundle: .module))
        }
        if ports.contains(where: { $0.host.trimmingCharacters(in: .whitespaces).isEmpty && !$0.container.isEmpty }) {
            warnings.append(String(localized: "apple/container cannot pick a host port. Ports without a host port are not published.", bundle: .module))
        }
        return warnings
    }

    private func dockerWarnings() -> [String] {
        var warnings: [String] = []
        if !dnsDomain.trimmingCharacters(in: .whitespaces).isEmpty {
            warnings.append(String(localized: "The DNS domain is for apple/container only. It is not used on this host.", bundle: .module))
        }
        if !kernel.trimmingCharacters(in: .whitespaces).isEmpty || !kernelArgs.isEmpty {
            warnings.append(String(localized: "Kernel options are for apple/container only. They are not used on this host.", bundle: .module))
        }
        return warnings
    }
}
