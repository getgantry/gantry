import Foundation
import DockerKit

/// Reads the original `container inspect` object of apple/container. The
/// Docker-shaped translation drops volume names, the `ro` option of binds,
/// the user and other fields, so the export reads the CLI object itself.
extension ServiceDraft {
    init(apple element: [String: Any], docker root: [String: Any], image: ImageConfig?) {
        self.init()
        let config = element["configuration"] as? [String: Any] ?? [:]
        let process = config["initProcess"] as? [String: Any] ?? [:]
        containerID = config["id"] as? String ?? element["id"] as? String ?? ""
        preferredName = containerID

        // The translation already decodes Gantry's escaped label values.
        let dockerConfig = root["Config"] as? [String: Any] ?? [:]
        let labels = dockerConfig["Labels"] as? [String: String] ?? config["labels"] as? [String: String] ?? [:]
        setLabels(labels, image: image?.labels ?? [:])
        if composeService == nil, !containerID.isEmpty {
            containerName = containerID
            fields["container_name"] = .str(containerID)
        }
        let imageObject = config["image"] as? [String: Any] ?? [:]
        let reference = imageObject["reference"] as? String ?? ""
        fields["image"] = .str(reference)
        addImageWarnings(image: reference, imageConfig: image)

        setAppleProcess(process, image: image)
        setEnvironment(process["environment"] as? [String] ?? [], image: image?.env ?? [])
        if let dir = process["workingDirectory"] as? String, !dir.isEmpty,
           dir != Self.defaultDirectory(image?.workingDir) {
            setString("working_dir", dir)
        }
        if let user = Self.appleUser(process["user"]), user != (image?.user ?? "") { setString("user", user) }
        if process["terminal"] as? Bool == true { fields["tty"] = .bool(true) }

        setApplePorts(config["publishedPorts"] as? [[String: Any]] ?? [])
        setAppleMounts(config["mounts"] as? [[String: Any]] ?? [])
        setAppleNetworks(config["networks"] as? [[String: Any]] ?? [])
        setAppleSettings(config, labels: labels)
    }

    /// The image working directory; an empty one means `/`.
    static func defaultDirectory(_ dir: String?) -> String {
        guard let dir, !dir.isEmpty else { return "/" }
        return dir
    }

    /// `user.raw.userString`, or `uid:gid` from `user.id` when it is not root.
    static func appleUser(_ value: Any?) -> String? {
        let user = value as? [String: Any] ?? [:]
        if let raw = (user["raw"] as? [String: Any])?["userString"] as? String, !raw.isEmpty { return raw }
        if let id = user["id"] as? [String: Any] {
            let uid = int(id["uid"]) ?? 0
            let gid = int(id["gid"]) ?? 0
            return uid == 0 && gid == 0 ? nil : "\(uid):\(gid)"
        }
        return nil
    }

    /// apple/container keeps one process: the image entrypoint and command
    /// joined, or what `--entrypoint` and the arguments gave.
    mutating func setAppleProcess(_ process: [String: Any], image: ImageConfig?) {
        let executable = process["executable"] as? String ?? ""
        let full = ([executable] + (process["arguments"] as? [String] ?? [])).filter { !$0.isEmpty }
        guard !full.isEmpty else { return }
        if let image {
            if full == image.entrypoint + image.cmd { return }
            if !image.entrypoint.isEmpty, full.starts(with: image.entrypoint) {
                fields["command"] = .list(full.dropFirst(image.entrypoint.count).map { .str($0) })
                return
            }
        }
        // A new entrypoint clears the image command, so this starts `full`.
        fields["entrypoint"] = .list(full.map { .str($0) })
    }

    mutating func setApplePorts(_ ports: [[String: Any]]) {
        var entries: [String] = []
        for port in ports {
            guard let container = Self.int(port["containerPort"]) else { continue }
            let host = Self.int(port["hostPort"]) ?? container
            let count = max(Self.int(port["count"]) ?? 1, 1)
            let hostText = count > 1 ? "\(host)-\(host + count - 1)" : "\(host)"
            let containerText = count > 1 ? "\(container)-\(container + count - 1)" : "\(container)"
            let text = ComposeExportFormat.port(
                hostIP: port["hostAddress"] as? String ?? "",
                host: hostText,
                container: containerText,
                proto: port["proto"] as? String ?? "tcp"
            )
            if !entries.contains(text) { entries.append(text) }
        }
        setList("ports", entries)
    }

    mutating func setAppleMounts(_ mounts: [[String: Any]]) {
        var tmpfs: [String] = []
        for mount in mounts.sorted(by: { ($0["destination"] as? String ?? "") < ($1["destination"] as? String ?? "") }) {
            let target = mount["destination"] as? String ?? ""
            guard !target.isEmpty else { continue }
            let options = mount["options"] as? [String] ?? []
            let readOnly = options.contains("ro") || mount["readOnly"] as? Bool == true
            let kind = Self.appleMountKind(mount["type"])
            switch kind.name {
            case "tmpfs":
                tmpfs.append(target)
            case "volume":
                let name = kind.body["name"] as? String ?? mount["name"] as? String ?? ""
                if name.isEmpty {
                    addAnonymousVolume(target: target)
                } else {
                    addVolume(type: "volume", source: name, target: target, readOnly: readOnly)
                }
            case "virtiofs", "bind":
                addVolume(type: "bind", source: mount["source"] as? String ?? "", target: target, readOnly: readOnly)
            default:
                warnings.append(Self.mountLeftOut(target: target, type: kind.name))
            }
        }
        setList("tmpfs", tmpfs)
    }

    /// The mount type: a string, or a `{"kind": {...}}` object.
    static func appleMountKind(_ value: Any?) -> (name: String, body: [String: Any]) {
        if let name = value as? String { return (name, [:]) }
        if let object = value as? [String: Any], let name = object.keys.sorted().first {
            return (name, object[name] as? [String: Any] ?? [:])
        }
        return ("", [:])
    }

    mutating func setAppleNetworks(_ networks: [[String: Any]]) {
        let names = networks.compactMap { $0["network"] as? String }.filter { !$0.isEmpty && $0 != "default" }
        networkNames = names
        setList("networks", names)
    }

    mutating func setAppleSettings(_ config: [String: Any], labels: [String: String]) {
        let resources = config["resources"] as? [String: Any] ?? [:]
        let cpus = Self.int(resources["cpus"]).flatMap { $0 > 0 ? String($0) : nil }
        let memory = Self.int(resources["memoryInBytes"])
        setResources(cpus: cpus, memory: memory)
        if cpus != nil || (memory ?? 0) > 0 {
            warnings.append(String(
                localized: "Apple container sets CPUs and memory for every container. Check that the limits in the file are the ones you want.",
                bundle: .module))
        }
        setList("cap_add", config["capAdd"] as? [String] ?? [])
        setList("cap_drop", config["capDrop"] as? [String] ?? [])
        if config["readOnly"] as? Bool == true { fields["read_only"] = .bool(true) }
        if config["useInit"] as? Bool == true { fields["init"] = .bool(true) }
        if let shm = Self.int(config["shmSize"]), shm > 0 { fields["shm_size"] = .str(ContainerRecipe.memoryText(bytes: shm)) }
        if let sysctls = config["sysctls"] as? [String: String], !sysctls.isEmpty {
            fields["sysctls"] = .map(sysctls.keys.sorted().map { ($0, .str(sysctls[$0] ?? "")) })
        }
        let dns = config["dns"] as? [String: Any] ?? [:]
        setList("dns", dns["nameservers"] as? [String] ?? [])
        setList("dns_search", dns["searchDomains"] as? [String] ?? [])
        setList("dns_opt", dns["options"] as? [String] ?? [])
        let process = config["initProcess"] as? [String: Any] ?? [:]
        if !(process["rlimits"] as? [Any] ?? []).isEmpty { warnings.append(Self.noSetting("--ulimit")) }
        addAppleWarnings(config, dns: dns, labels: labels)
    }

    /// Settings of apple/container that Compose has no key for.
    mutating func addAppleWarnings(_ config: [String: Any], dns: [String: Any], labels: [String: String]) {
        let apple = ContainerCreateRequest.AppleOptions(labels: labels)
        if apple.kernel?.isEmpty == false || config["kernel"] != nil { warnings.append(Self.noSetting("--kernel")) }
        if !apple.kernelArgs.isEmpty { warnings.append(Self.noSetting("--kernel-arg")) }
        let domain = (dns["domain"] as? String) ?? labels[ContainerRecipe.dnsDomainLabelKey] ?? ""
        if !domain.isEmpty { warnings.append(Self.noSetting("--dns-domain \(domain)")) }
        if config["rosetta"] as? Bool == true { warnings.append(Self.noSetting("--rosetta")) }
        if config["virtualization"] as? Bool == true { warnings.append(Self.noSetting("--virtualization")) }
        if config["ssh"] as? Bool == true { warnings.append(Self.noSetting("--ssh")) }
        if !(config["publishedSockets"] as? [Any] ?? []).isEmpty { warnings.append(Self.noSetting("--publish-socket")) }
    }
}
