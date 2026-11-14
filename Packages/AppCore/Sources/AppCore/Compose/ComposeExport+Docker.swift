import Foundation

/// Reads a Docker Engine `GET /containers/{id}/json` body.
extension ServiceDraft {
    init(docker root: [String: Any], image: ImageConfig?, isRemoteHost: Bool) {
        self.init()
        let config = root["Config"] as? [String: Any] ?? [:]
        let host = root["HostConfig"] as? [String: Any] ?? [:]
        containerID = root["Id"] as? String ?? ""
        let name = (root["Name"] as? String ?? "").trimmingPrefix("/")
        preferredName = name.isEmpty ? String(containerID.prefix(12)) : name

        setLabels(config["Labels"] as? [String: String] ?? [:], image: image?.labels ?? [:])
        if composeService == nil, !name.isEmpty {
            containerName = name
            fields["container_name"] = .str(name)
        }
        let reference = (config["Image"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? root["Image"] as? String ?? ""
        fields["image"] = .str(reference)
        addImageWarnings(image: reference, imageConfig: image)

        setProcess(
            entrypoint: config["Entrypoint"] as? [String] ?? [],
            command: config["Cmd"] as? [String] ?? [],
            image: image
        )
        setEnvironment(config["Env"] as? [String] ?? [], image: image?.env ?? [])
        if let dir = config["WorkingDir"] as? String, dir != (image?.workingDir ?? "") { setString("working_dir", dir) }
        if let user = config["User"] as? String, user != (image?.user ?? "") { setString("user", user) }

        let networkMode = host["NetworkMode"] as? String ?? ""
        if let hostname = config["Hostname"] as? String, !hostname.isEmpty,
           !containerID.hasPrefix(hostname), networkMode != "host" {
            setString("hostname", hostname)
        }
        setString("domainname", config["Domainname"] as? String)
        if config["Tty"] as? Bool == true { fields["tty"] = .bool(true) }
        if config["OpenStdin"] as? Bool == true { fields["stdin_open"] = .bool(true) }
        if let signal = config["StopSignal"] as? String, signal != (image?.stopSignal ?? "") {
            setString("stop_signal", signal)
        }
        if let timeout = Self.int(config["StopTimeout"]), timeout >= 0 {
            fields["stop_grace_period"] = .str("\(timeout)s")
        }
        setHealthcheck(config["Healthcheck"] as? [String: Any], image: image)

        setDockerPorts(host: host, settings: root["NetworkSettings"] as? [String: Any] ?? [:])
        setDockerMounts(root["Mounts"] as? [[String: Any]] ?? [], host: host, isRemoteHost: isRemoteHost)
        setDockerNetworks(mode: networkMode, settings: root["NetworkSettings"] as? [String: Any] ?? [:], name: name)
        setRestart(host["RestartPolicy"] as? [String: Any])
        setDockerHostSettings(host)
    }

    static func int(_ value: Any?) -> Int64? {
        switch value {
        case let number as Int: Int64(number)
        case let number as Int64: number
        case let number as Double: Int64(number)
        case let number as NSNumber: number.int64Value
        default: nil
        }
    }

    // MARK: Healthcheck

    mutating func setHealthcheck(_ check: [String: Any]?, image: ImageConfig?) {
        guard let check, let test = check["Test"] as? [String], !test.isEmpty else { return }
        if let own = image?.healthcheck, own.isEqual(to: check) { return }
        if test == ["NONE"] {
            fields["healthcheck"] = .map([("disable", .bool(true))])
            return
        }
        var entry: [(String, YValue)] = [("test", .list(test.map { .str($0) }))]
        for (key, name) in [("Interval", "interval"), ("Timeout", "timeout"),
                            ("StartPeriod", "start_period"), ("StartInterval", "start_interval")] {
            if let value = Self.int(check[key]), value > 0 {
                entry.append((name, .str(ComposeExportFormat.duration(nanoseconds: value))))
            }
        }
        if let retries = Self.int(check["Retries"]), retries > 0 { entry.append(("retries", .int(retries))) }
        fields["healthcheck"] = .map(entry)
    }

    // MARK: Ports

    /// Requested bindings first (they survive a stop), then live ones. An
    /// IPv4 and IPv6 "any" pair becomes one entry.
    mutating func setDockerPorts(host: [String: Any], settings: [String: Any]) {
        let candidates = [host["PortBindings"], settings["Ports"]].compactMap { $0 as? [String: Any] }
        guard let map = candidates.first(where: { map in
            map.values.contains { !(($0 as? [[String: Any]]) ?? []).isEmpty }
        }) else { return }
        var ports: [String] = []
        for key in map.keys.sorted(by: Self.portOrder) {
            let parts = key.split(separator: "/").map(String.init)
            for binding in map[key] as? [[String: Any]] ?? [] {
                let text = ComposeExportFormat.port(
                    hostIP: binding["HostIp"] as? String ?? "",
                    host: binding["HostPort"] as? String ?? "",
                    container: parts.first ?? key,
                    proto: parts.count > 1 ? parts[1] : "tcp"
                )
                if !ports.contains(text) { ports.append(text) }
            }
        }
        if !ports.isEmpty { fields["ports"] = .list(ports.map { .str($0) }) }
    }

    static func portOrder(_ a: String, _ b: String) -> Bool {
        let left = Int(a.split(separator: "/").first ?? "") ?? 0
        let right = Int(b.split(separator: "/").first ?? "") ?? 0
        return left == right ? a < b : left < right
    }

    // MARK: Mounts

    mutating func setDockerMounts(_ mounts: [[String: Any]], host: [String: Any], isRemoteHost: Bool) {
        var hasBind = false
        var tmpfs: [String] = []
        for mount in mounts.sorted(by: { ($0["Destination"] as? String ?? "") < ($1["Destination"] as? String ?? "") }) {
            let type = mount["Type"] as? String ?? ""
            let target = mount["Destination"] as? String ?? ""
            guard !target.isEmpty else { continue }
            let readOnly = mount["RW"] as? Bool == false
            let mode = (mount["Mode"] as? String ?? "").split(separator: ",").map(String.init)
            switch type {
            case "bind":
                hasBind = true
                addVolume(type: "bind", source: mount["Source"] as? String ?? "", target: target,
                          readOnly: readOnly, modes: mode.filter { ["z", "Z"].contains($0) })
            case "volume":
                let name = mount["Name"] as? String ?? ""
                if Self.isAnonymousVolume(name) {
                    addAnonymousVolume(target: target)
                } else {
                    addVolume(type: "volume", source: name, target: target, readOnly: readOnly)
                }
            case "tmpfs":
                tmpfs.append(target)
            default:
                warnings.append(Self.mountLeftOut(target: target, type: type))
            }
        }
        for (path, options) in (host["Tmpfs"] as? [String: String] ?? [:]).sorted(by: { $0.key < $1.key }) {
            tmpfs.removeAll { $0 == path }
            tmpfs.append(options.isEmpty ? path : "\(path):\(options)")
        }
        setList("tmpfs", tmpfs)
        setList("volumes_from", (host["VolumesFrom"] as? [String] ?? []).map { "container:" + $0 })
        if hasBind, isRemoteHost {
            warnings.append(String(localized: "Bind sources are paths on the remote host.", bundle: .module))
        }
    }

    /// Docker names anonymous volumes with 64 hex characters.
    static func isAnonymousVolume(_ name: String) -> Bool {
        name.count == 64 && name.allSatisfy(\.isHexDigit)
    }

    // MARK: Networks

    mutating func setDockerNetworks(mode: String, settings: [String: Any], name: String) {
        if ["host", "none"].contains(mode) || mode.hasPrefix("container:") || mode.hasPrefix("service:") {
            networkMode = mode
            return
        }
        let attached = settings["Networks"] as? [String: [String: Any]] ?? [:]
        let shortID = String(containerID.prefix(12))
        var entries: [(String, YValue)] = []
        var detailed = false
        for network in attached.keys.sorted() where !["bridge", "default"].contains(network) {
            let endpoint = attached[network] ?? [:]
            var body: [(String, YValue)] = []
            let aliases = (endpoint["Aliases"] as? [String] ?? [])
                .filter { $0 != name && $0 != shortID && $0 != composeService && !containerID.hasPrefix($0) }
            if !aliases.isEmpty { body.append(("aliases", .list(aliases.map { .str($0) }))) }
            let ipam = endpoint["IPAMConfig"] as? [String: Any] ?? [:]
            if let address = ipam["IPv4Address"] as? String, !address.isEmpty { body.append(("ipv4_address", .str(address))) }
            if let address = ipam["IPv6Address"] as? String, !address.isEmpty { body.append(("ipv6_address", .str(address))) }
            detailed = detailed || !body.isEmpty
            entries.append((network, .map(body)))
            networkNames.append(network)
        }
        guard !entries.isEmpty else {
            if !["", "default", "bridge"].contains(mode), attached.isEmpty {
                networkMode = mode
            }
            return
        }
        fields["networks"] = detailed ? .map(entries) : .list(entries.map { .str($0.0) })
    }

    // MARK: Restart

    mutating func setRestart(_ policy: [String: Any]?) {
        let name = policy?["Name"] as? String ?? ""
        guard !name.isEmpty, name != "no" else { return }
        if name == "on-failure", let retries = Self.int(policy?["MaximumRetryCount"]), retries > 0 {
            fields["restart"] = .str("on-failure:\(retries)")
        } else {
            fields["restart"] = .str(name)
        }
    }

    // MARK: Other host settings

    mutating func setDockerHostSettings(_ host: [String: Any]) {
        let nano = Self.int(host["NanoCpus"]) ?? 0
        let quota = Self.int(host["CpuQuota"]) ?? 0
        let period = Self.int(host["CpuPeriod"]) ?? 0
        var cpus: String?
        if nano > 0 {
            cpus = ContainerRecipe.cpusText(nanoCPUs: nano)
        } else if quota > 0 {
            cpus = ContainerRecipe.cpusText(nanoCPUs: quota * 1_000_000_000 / (period > 0 ? period : 100_000))
        }
        setResources(
            cpus: cpus,
            memory: Self.int(host["Memory"]),
            reservation: Self.int(host["MemoryReservation"]),
            pids: Self.int(host["PidsLimit"])
        )
        if let shares = Self.int(host["CpuShares"]), shares > 0, shares != 1024 { fields["cpu_shares"] = .int(shares) }
        setString("cpuset", host["CpusetCpus"] as? String)
        if host["Privileged"] as? Bool == true { fields["privileged"] = .bool(true) }
        if host["ReadonlyRootfs"] as? Bool == true { fields["read_only"] = .bool(true) }
        if host["Init"] as? Bool == true { fields["init"] = .bool(true) }
        if host["OomKillDisable"] as? Bool == true { fields["oom_kill_disable"] = .bool(true) }
        setList("cap_add", host["CapAdd"] as? [String] ?? [])
        setList("cap_drop", host["CapDrop"] as? [String] ?? [])
        setList("dns", host["Dns"] as? [String] ?? [])
        setList("dns_search", host["DnsSearch"] as? [String] ?? [])
        setList("dns_opt", host["DnsOptions"] as? [String] ?? [])
        setList("extra_hosts", host["ExtraHosts"] as? [String] ?? [])
        setList("security_opt", host["SecurityOpt"] as? [String] ?? [])
        setList("group_add", host["GroupAdd"] as? [String] ?? [])
        setList("devices", (host["Devices"] as? [[String: Any]] ?? []).compactMap(Self.device))
        if let shm = Self.int(host["ShmSize"]), shm > 0, shm != 64 * 1024 * 1024 {
            fields["shm_size"] = .str(ContainerRecipe.memoryText(bytes: shm))
        }
        for key in ["PidMode": "pid", "IpcMode": "ipc", "UTSMode": "uts", "UsernsMode": "userns_mode"] {
            let value = host[key.key] as? String ?? ""
            if value == "host" || value.hasPrefix("container:") { fields[key.value] = .str(value) }
        }
        if let runtime = host["Runtime"] as? String, !runtime.isEmpty, runtime != "runc" { fields["runtime"] = .str(runtime) }
        if let sysctls = host["Sysctls"] as? [String: String], !sysctls.isEmpty {
            fields["sysctls"] = .map(sysctls.keys.sorted().map { ($0, .str(sysctls[$0] ?? "")) })
        }
        setUlimits(host["Ulimits"] as? [[String: Any]] ?? [])
        setLogging(host["LogConfig"] as? [String: Any])
        if host["AutoRemove"] as? Bool == true { warnings.append(Self.noSetting("--rm")) }
        if !(host["Links"] as? [String] ?? []).isEmpty { warnings.append(Self.noSetting("--link")) }
    }

    static func device(_ device: [String: Any]) -> String? {
        let hostPath = device["PathOnHost"] as? String ?? ""
        guard !hostPath.isEmpty else { return nil }
        let container = device["PathInContainer"] as? String ?? ""
        let permissions = device["CgroupPermissions"] as? String ?? ""
        var parts = [hostPath, container.isEmpty ? hostPath : container]
        if !permissions.isEmpty, permissions != "rwm" { parts.append(permissions) }
        return parts.joined(separator: ":")
    }

    mutating func setUlimits(_ limits: [[String: Any]]) {
        var entries: [(String, YValue)] = []
        for limit in limits {
            guard let name = limit["Name"] as? String, !name.isEmpty else { continue }
            let soft = Self.int(limit["Soft"]) ?? 0
            let hard = Self.int(limit["Hard"]) ?? soft
            entries.append((name, soft == hard ? .int(soft) : .map([("soft", .int(soft)), ("hard", .int(hard))])))
        }
        if !entries.isEmpty { fields["ulimits"] = .map(entries) }
    }

    mutating func setLogging(_ log: [String: Any]?) {
        let driver = log?["Type"] as? String ?? ""
        let options = log?["Config"] as? [String: String] ?? [:]
        guard !driver.isEmpty, driver != "json-file" || !options.isEmpty else { return }
        var entry: [(String, YValue)] = [("driver", .str(driver))]
        if !options.isEmpty { entry.append(("options", .map(options.keys.sorted().map { ($0, .str(options[$0] ?? "")) }))) }
        fields["logging"] = .map(entry)
    }
}

extension String {
    fileprivate func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
