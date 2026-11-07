import Foundation

/// Value parsers for ``RunCommandParser``: ports, volumes, mounts and the
/// other flags whose value has its own small syntax.
enum RunCommandValues {
    typealias State = RunCommandParser.State

    /// Largest port range that is expanded into rows.
    static let maxRangeSize = 100

    // MARK: - Ports

    /// `[ip:][host:]container[/proto]`, where host and container can be
    /// ranges such as `8000-8002`.
    static func addPorts(_ value: String, raw: String, state: inout State) {
        guard let ports = ports(value) else {
            state.reject(raw, String(localized: "This port mapping is not valid or not supported.", bundle: .module))
            return
        }
        state.recipe.ports += ports
    }

    static func ports(_ value: String) -> [ContainerRecipe.Port]? {
        var spec = value
        var proto = "tcp"
        if let slash = spec.lastIndex(of: "/") {
            proto = String(spec[spec.index(after: slash)...]).lowercased()
            spec = String(spec[..<slash])
        }
        guard ["tcp", "udp"].contains(proto) else { return nil }
        guard let (ip, host, container) = splitPortSpec(spec) else { return nil }
        guard let containerRange = portRange(container) else { return nil }
        if host.isEmpty {
            return containerRange.map { .init(hostIP: ip, host: "", container: String($0), proto: proto) }
        }
        guard let hostRange = portRange(host), hostRange.count == containerRange.count else { return nil }
        return zip(hostRange, containerRange).map {
            .init(hostIP: ip, host: String($0), container: String($1), proto: proto)
        }
    }

    /// Splits off the host IP (IPv6 in brackets) and the host port.
    private static func splitPortSpec(_ spec: String) -> (String, String, String)? {
        var rest = spec
        var ip = ""
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            ip = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = String(rest[rest.index(after: close)...])
            guard rest.hasPrefix(":") else { return nil }
            rest.removeFirst()
            let parts = rest.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return nil }
            return (ip, parts[0], parts[1])
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1: return ("", "", parts[0])
        case 2: return ("", parts[0], parts[1])
        case 3: return (parts[0], parts[1], parts[2])
        default: return nil
        }
    }

    private static func portRange(_ text: String) -> [Int]? {
        let bounds = text.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...2).contains(bounds.count), bounds.allSatisfy({ $0 != nil }) else { return nil }
        let low = bounds[0]!, high = bounds.last!!
        guard (1...65535).contains(low), (1...65535).contains(high), low <= high,
              high - low < maxRangeSize else { return nil }
        return Array(low...high)
    }

    // MARK: - Environment and labels

    static func addEnv(_ value: String, state: inout State) {
        if let eq = value.firstIndex(of: "=") {
            state.recipe.env.append(.init(key: String(value[..<eq]), value: String(value[value.index(after: eq)...])))
        } else {
            state.recipe.env.append(.init(key: value, value: ""))
            state.note(String(localized: "\(value) takes its value from your shell. Enter the value in the form.", bundle: .module))
        }
    }

    static func addLabel(_ value: String, state: inout State) {
        if let eq = value.firstIndex(of: "=") {
            state.recipe.labels.append(.init(key: String(value[..<eq]), value: String(value[value.index(after: eq)...])))
        } else {
            state.recipe.labels.append(.init(key: value, value: ""))
        }
    }

    // MARK: - Volumes

    /// `source:target[:options]`. A lone path is an anonymous volume, which
    /// the form cannot hold.
    static func addVolume(_ value: String, raw: String, state: inout State) {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.count <= 3, !parts[0].isEmpty, !parts[1].isEmpty else {
            let reason = parts.count == 1
                ? String(localized: "Anonymous volumes are not supported. Give a host path or a volume name.", bundle: .module)
                : String(localized: "This volume is not valid.", bundle: .module)
            state.reject(raw, reason)
            return
        }
        var readOnly = false
        if parts.count == 3 {
            for option in parts[2].split(separator: ",").map(String.init) {
                switch option {
                case "ro", "readonly": readOnly = true
                case "rw": readOnly = false
                default:
                    state.note(String(localized: "The volume option “\(option)” is not used.", bundle: .module))
                }
            }
        }
        state.recipe.volumes.append(.init(source: parts[0], target: parts[1], readOnly: readOnly))
    }

    /// `type=bind,source=/a,target=/b,readonly`.
    static func addMount(_ value: String, raw: String, state: inout State) {
        var fields: [String: String] = [:]
        for part in value.split(separator: ",").map(String.init) {
            if let eq = part.firstIndex(of: "=") {
                fields[String(part[..<eq]).lowercased()] = String(part[part.index(after: eq)...])
            } else {
                fields[part.lowercased()] = "true"
            }
        }
        let type = fields["type"] ?? "volume"
        let source = fields["source"] ?? fields["src"] ?? ""
        let target = fields["target"] ?? fields["destination"] ?? fields["dst"] ?? ""
        guard type == "bind" || type == "volume" else {
            state.reject(raw, String(localized: "Mounts of type “\(type)” are not supported.", bundle: .module))
            return
        }
        guard !source.isEmpty, !target.isEmpty else {
            state.reject(raw, String(localized: "Anonymous volumes are not supported. Give a host path or a volume name.", bundle: .module))
            return
        }
        let flag = (fields["readonly"] ?? fields["ro"])?.lowercased()
        let readOnly = flag.map { !["false", "0"].contains($0) } ?? false
        let known: Set<String> = ["type", "source", "src", "target", "destination", "dst", "readonly", "ro"]
        for key in fields.keys.sorted() where !known.contains(key) {
            state.note(String(localized: "The mount option “\(key)” is not used.", bundle: .module))
        }
        state.recipe.volumes.append(.init(source: source, target: target, readOnly: readOnly))
    }

    // MARK: - Other values

    static func setNetwork(_ value: String, raw: String, state: inout State) {
        // `--network name,alias=x` (apple/container) keeps only the name.
        let name = value.split(separator: ",").first.map(String.init) ?? value
        if !state.recipe.network.isEmpty, state.recipe.network != name {
            state.reject(raw, String(localized: "Only one network is supported. The first network is used.", bundle: .module))
            return
        }
        if name != value {
            state.note(String(localized: "Network options after the name are not used.", bundle: .module))
        }
        state.recipe.network = name
    }

    static func setRestart(_ value: String, raw: String, state: inout State) {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        let policy = parts.first ?? ""
        guard ContainerRecipe.restartPolicies.contains(policy) else {
            state.reject(raw, String(localized: "This restart policy is not valid.", bundle: .module))
            return
        }
        if parts.count == 2 {
            state.note(String(localized: "The retry count \(parts[1]) is not used. The policy restarts without a limit.", bundle: .module))
        }
        state.recipe.restartPolicy = policy
    }

    static func setCPUs(_ value: String, raw: String, state: inout State) {
        guard ContainerRecipe.nanoCPUs(value) != nil else {
            state.reject(raw, String(localized: "This CPU count is not valid.", bundle: .module))
            return
        }
        state.recipe.cpus = value
    }

    static func setMemory(_ value: String, raw: String, state: inout State) {
        guard ContainerRecipe.memoryBytes(value) != nil else {
            state.reject(raw, String(localized: "This memory size is not valid.", bundle: .module))
            return
        }
        state.recipe.memory = value
    }
}
