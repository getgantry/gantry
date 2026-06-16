import Foundation
import Yams

/// Turns a `docker-compose.yml` on disk into a `ComposeProject`.
///
/// Supports the slice of the Compose spec that maps cleanly onto `container`
/// CLI runs: services with `image`/`build`, ports, environment (+ `env_file`),
/// volumes (bind and named), networks, `depends_on`, labels, command/entrypoint,
/// working_dir, user, tty, and memory/cpu limits. Variable interpolation
/// (`${VAR}`, `${VAR:-default}`, `${VAR-default}`) is resolved from the process
/// environment overlaid on a sibling `.env` file.
public struct ComposeParser: Sendable {
    public init() {}

    /// Parses the compose file at `fileURL`. `environment` overrides the values
    /// used for `${VAR}` interpolation (defaults to the process environment,
    /// merged over a sibling `.env`); inject it in tests for determinism.
    public func parse(fileURL: URL, environment: [String: String]? = nil) throws -> ComposeProject {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw ComposeParseError.notReadable(fileURL.path)
        }
        let directory = fileURL.deletingLastPathComponent()
        let interp = environment ?? Self.defaultEnvironment(projectDir: directory)
        return try parse(text: text, fileURL: fileURL, directory: directory, environment: interp)
    }

    /// Parses edited YAML text for a file at `fileURL`, deriving the project
    /// directory and interpolation environment the same way the on-disk entry
    /// point does. Used by the in-sheet YAML editor.
    public func parse(text: String, fileURL: URL, environment: [String: String]? = nil) throws -> ComposeProject {
        let directory = fileURL.deletingLastPathComponent()
        let interp = environment ?? Self.defaultEnvironment(projectDir: directory)
        return try parse(text: text, fileURL: fileURL, directory: directory, environment: interp)
    }

    /// Core parse over raw YAML text (the on-disk entry point delegates here).
    public func parse(
        text: String,
        fileURL: URL,
        directory: URL,
        environment: [String: String]
    ) throws -> ComposeProject {
        let node: Any?
        do {
            node = try Yams.load(yaml: text)
        } catch {
            throw ComposeParseError.invalidYAML(String(describing: error))
        }
        guard let root = node as? [String: Any] else {
            throw ComposeParseError.invalidYAML("top level is not a mapping")
        }

        let env = Interpolator(environment: environment)
        guard let servicesRaw = root["services"] as? [String: Any], !servicesRaw.isEmpty else {
            throw ComposeParseError.noServices
        }

        // Preserve declaration order where YAML gives it to us; Yams returns a
        // plain dictionary, so sort by key for a stable, predictable order.
        var services: [ComposeService] = []
        for key in servicesRaw.keys.sorted() {
            guard let body = servicesRaw[key] as? [String: Any] else { continue }
            services.append(try parseService(name: key, body: body, env: env))
        }

        let project = root["name"].flatMap { env.string($0) }?.nonEmpty
            ?? Self.defaultProjectName(directory: directory)

        return ComposeProject(
            name: project,
            services: services,
            networks: parseNetworks(root["networks"], env: env),
            volumes: parseVolumes(root["volumes"], env: env),
            filePath: fileURL,
            directory: directory
        )
    }

    // MARK: - Services

    private func parseService(name: String, body: [String: Any], env: Interpolator) throws -> ComposeService {
        var service = ComposeService(name: name)
        service.image = (body["image"]).flatMap { env.string($0) }?.nonEmpty
        service.build = parseBuild(body["build"], env: env)
        if service.image == nil && service.build == nil {
            throw ComposeParseError.serviceMissingImageAndBuild(name)
        }
        service.containerName = (body["container_name"]).flatMap { env.string($0) }?.nonEmpty
        service.command = parseStringOrList(body["command"], env: env)
        service.entrypoint = parseStringOrList(body["entrypoint"], env: env)
        service.environment = parseEnvironment(body["environment"], env: env)
        service.envFiles = parseScalarList(body["env_file"], env: env)
        service.ports = parsePorts(body["ports"], env: env)
        service.volumes = parseMounts(body["volumes"], env: env)
        service.networks = parseKeyedList(body["networks"], env: env)
        service.dependsOn = parseKeyedList(body["depends_on"], env: env)
        service.labels = parseLabels(body["labels"], env: env)
        service.restart = (body["restart"]).flatMap { env.string($0) }?.nonEmpty
        service.workingDir = (body["working_dir"]).flatMap { env.string($0) }?.nonEmpty
        service.user = (body["user"]).flatMap { env.string($0) }?.nonEmpty
        service.tty = parseBool(body["tty"])
        service.privileged = parseBool(body["privileged"])
        service.memoryBytes = parseMemory(body["mem_limit"], env: env)
            ?? parseMemory(deepValue(body, "deploy", "resources", "limits", "memory"), env: env)
        service.cpus = parseCPUs(body["cpus"], env: env)
            ?? parseCPUs(deepValue(body, "deploy", "resources", "limits", "cpus"), env: env)
        return service
    }

    private func parseBuild(_ value: Any?, env: Interpolator) -> ComposeBuild? {
        if let str = value as? String {
            return ComposeBuild(context: env.interpolate(str))
        }
        guard let map = value as? [String: Any] else { return nil }
        let context = (map["context"]).flatMap { env.string($0) } ?? "."
        let dockerfile = (map["dockerfile"]).flatMap { env.string($0) }?.nonEmpty
        let target = (map["target"]).flatMap { env.string($0) }?.nonEmpty
        var args: [String: String] = [:]
        for pair in parseEnvironment(map["args"], env: env) { args[pair.key] = pair.value }
        return ComposeBuild(context: context, dockerfile: dockerfile, args: args, target: target)
    }

    // MARK: - Field parsers

    /// A `command:`/`entrypoint:` value: a list verbatim, or a string tokenized
    /// on whitespace (Compose's shell-style splitting, sans full quote parsing).
    private func parseStringOrList(_ value: Any?, env: Interpolator) -> [String]? {
        if let list = value as? [Any] {
            return list.map { env.string($0) ?? "" }
        }
        if let str = value as? String {
            let interpolated = env.interpolate(str)
            let tokens = interpolated.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            return tokens.isEmpty ? nil : tokens
        }
        return nil
    }

    /// A plain list of scalars (e.g. `env_file`), or a single scalar.
    private func parseScalarList(_ value: Any?, env: Interpolator) -> [String] {
        if let list = value as? [Any] { return list.compactMap { env.string($0)?.nonEmpty } }
        if let str = value as? String, let v = env.interpolate(str).nonEmpty { return [v] }
        return []
    }

    /// `environment:` as a `K=V`/`K` list or a `{K: V}` map → ordered pairs.
    private func parseEnvironment(_ value: Any?, env: Interpolator) -> [(key: String, value: String)] {
        var result: [(key: String, value: String)] = []
        if let list = value as? [Any] {
            for item in list {
                guard let raw = env.string(item) else { continue }
                if let eq = raw.firstIndex(of: "=") {
                    result.append((String(raw[..<eq]), String(raw[raw.index(after: eq)...])))
                } else {
                    // Bare `KEY` takes its value from the interpolation env.
                    result.append((raw, env.lookup(raw) ?? ""))
                }
            }
        } else if let map = value as? [String: Any] {
            for key in map.keys.sorted() {
                result.append((key, env.string(map[key]) ?? ""))
            }
        }
        return result
    }

    /// `labels:` as a `K=V` list or `{K: V}` map → dictionary.
    private func parseLabels(_ value: Any?, env: Interpolator) -> [String: String] {
        var result: [String: String] = [:]
        for pair in parseEnvironment(value, env: env) { result[pair.key] = pair.value }
        return result
    }

    /// `networks:`/`depends_on:` as a list of keys or a map keyed by name.
    private func parseKeyedList(_ value: Any?, env: Interpolator) -> [String] {
        if let list = value as? [Any] { return list.compactMap { env.string($0)?.nonEmpty } }
        if let map = value as? [String: Any] { return map.keys.sorted() }
        return []
    }

    private func parsePorts(_ value: Any?, env: Interpolator) -> [ComposePort] {
        guard let list = value as? [Any] else { return [] }
        var ports: [ComposePort] = []
        for item in list {
            if let map = item as? [String: Any] {
                let target = env.string(map["target"]) ?? ""
                guard !target.isEmpty else { continue }
                ports.append(ComposePort(
                    hostIP: env.string(map["host_ip"])?.nonEmpty,
                    hostPort: env.string(map["published"])?.nonEmpty,
                    containerPort: target,
                    proto: (env.string(map["protocol"])?.nonEmpty ?? "tcp").lowercased()
                ))
            } else if let raw = env.string(item) {
                if let port = Self.parsePortString(raw) { ports.append(port) }
            }
        }
        return ports
    }

    /// Parses `"[ip:][host:]container[/proto]"`. Ranges are kept verbatim.
    static func parsePortString(_ raw: String) -> ComposePort? {
        var spec = raw
        var proto = "tcp"
        if let slash = spec.lastIndex(of: "/") {
            proto = String(spec[spec.index(after: slash)...]).lowercased()
            spec = String(spec[..<slash])
        }
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            return ComposePort(hostPort: nil, containerPort: parts[0], proto: proto)
        case 2:
            return ComposePort(hostPort: parts[0].nonEmpty, containerPort: parts[1], proto: proto)
        case 3:
            return ComposePort(hostIP: parts[0].nonEmpty, hostPort: parts[1].nonEmpty,
                               containerPort: parts[2], proto: proto)
        default:
            return nil
        }
    }

    private func parseMounts(_ value: Any?, env: Interpolator) -> [ComposeMount] {
        guard let list = value as? [Any] else { return [] }
        var mounts: [ComposeMount] = []
        for item in list {
            if let map = item as? [String: Any] {
                let target = env.string(map["target"]) ?? ""
                guard !target.isEmpty else { continue }
                let source = env.string(map["source"])?.nonEmpty
                let readOnly = parseBool(map["read_only"])
                let type = (env.string(map["type"])?.nonEmpty ?? "volume").lowercased()
                if type == "bind", let source {
                    mounts.append(ComposeMount(kind: .bind(hostPath: source), containerPath: target, readOnly: readOnly))
                } else if let source {
                    mounts.append(ComposeMount(kind: .named(volume: source), containerPath: target, readOnly: readOnly))
                }
            } else if let raw = env.string(item), let mount = Self.parseMountString(raw) {
                mounts.append(mount)
            }
        }
        return mounts
    }

    /// Parses `"source:target[:ro]"` (or an anonymous `"/in/container"`).
    static func parseMountString(_ raw: String) -> ComposeMount? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            // Anonymous volume — give it a deterministic name from the path.
            let path = parts[0]
            let name = "anon" + path.replacingOccurrences(of: "/", with: "_")
            return ComposeMount(kind: .named(volume: name), containerPath: path)
        case 2, 3:
            let source = parts[0], target = parts[1]
            let readOnly = parts.count == 3 && (parts[2] == "ro" || parts[2].contains("ro"))
            if Self.isHostPath(source) {
                return ComposeMount(kind: .bind(hostPath: source), containerPath: target, readOnly: readOnly)
            }
            return ComposeMount(kind: .named(volume: source), containerPath: target, readOnly: readOnly)
        default:
            return nil
        }
    }

    static func isHostPath(_ source: String) -> Bool {
        source.hasPrefix("/") || source.hasPrefix("./") || source.hasPrefix("../")
            || source.hasPrefix("~") || source == "."
    }

    // MARK: - Top-level networks / volumes

    private func parseNetworks(_ value: Any?, env: Interpolator) -> [String: ComposeNetwork] {
        guard let map = value as? [String: Any] else { return [:] }
        var result: [String: ComposeNetwork] = [:]
        for (key, body) in map {
            let def = body as? [String: Any] ?? [:]
            result[key] = ComposeNetwork(
                external: parseBool(def["external"]),
                name: env.string(def["name"])?.nonEmpty,
                labels: parseLabels(def["labels"], env: env)
            )
        }
        return result
    }

    private func parseVolumes(_ value: Any?, env: Interpolator) -> [String: ComposeVolume] {
        guard let map = value as? [String: Any] else { return [:] }
        var result: [String: ComposeVolume] = [:]
        for (key, body) in map {
            let def = body as? [String: Any] ?? [:]
            result[key] = ComposeVolume(
                external: parseBool(def["external"]),
                name: env.string(def["name"])?.nonEmpty,
                labels: parseLabels(def["labels"], env: env)
            )
        }
        return result
    }

    // MARK: - Scalar helpers

    private func parseBool(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: return b
        case let s as String: return ["true", "1", "yes", "on"].contains(s.lowercased())
        case let i as Int: return i != 0
        default: return false
        }
    }

    private func parseMemory(_ value: Any?, env: Interpolator) -> Int64? {
        switch value {
        case let i as Int: return Int64(i)
        case let s as String: return Self.parseByteSize(env.interpolate(s))
        default: return nil
        }
    }

    /// Parses `"512m"`, `"1g"`, `"1024"` → bytes.
    static func parseByteSize(_ raw: String) -> Int64? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        let units: [(String, Int64)] = [("k", 1024), ("m", 1024 * 1024), ("g", 1024 * 1024 * 1024),
                                        ("kb", 1024), ("mb", 1024 * 1024), ("gb", 1024 * 1024 * 1024)]
        for (suffix, mult) in units.sorted(by: { $0.0.count > $1.0.count }) where s.hasSuffix(suffix) {
            let number = s.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            if let v = Double(number) { return Int64(v * Double(mult)) }
        }
        return Int64(s)
    }

    private func parseCPUs(_ value: Any?, env: Interpolator) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(env.interpolate(s))
        default: return nil
        }
    }

    /// Walks a nested mapping by key path, returning the leaf value if present.
    private func deepValue(_ root: [String: Any], _ keys: String...) -> Any? {
        var current: Any? = root
        for key in keys {
            guard let map = current as? [String: Any] else { return nil }
            current = map[key]
        }
        return current
    }

    // MARK: - Project name / env defaults

    /// Compose's default project name: the parent directory, lowercased, with
    /// non-alphanumeric runs collapsed to single separators.
    static func defaultProjectName(directory: URL) -> String {
        let base = directory.lastPathComponent.lowercased()
        let mapped = base.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "compose" : collapsed
    }

    /// Process environment overlaid on a sibling `.env` file (shell wins).
    static func defaultEnvironment(projectDir: URL) -> [String: String] {
        var env = parseDotEnv(at: projectDir.appendingPathComponent(".env"))
        for (k, v) in ProcessInfo.processInfo.environment { env[k] = v }
        return env
    }

    /// Reads a `.env` file (`KEY=VALUE`, `#` comments). Best-effort.
    static func parseDotEnv(at url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }
}

/// Resolves `${VAR}` style interpolation in scalar values.
struct Interpolator: Sendable {
    let environment: [String: String]

    func lookup(_ key: String) -> String? { environment[key] }

    /// Coerces a YAML scalar to its string form (numbers, bools), interpolating
    /// any `${VAR}` in string values. Returns nil for containers/null.
    func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return interpolate(s)
        case let i as Int: return String(i)
        case let d as Double: return String(d)
        case let b as Bool: return b ? "true" : "false"
        default: return nil
        }
    }

    /// Expands `$$` (escape), `${VAR}`, `${VAR:-default}`, `${VAR-default}`,
    /// `${VAR:?msg}` and bare `$VAR`. Unknown variables expand to empty.
    func interpolate(_ input: String) -> String {
        guard input.contains("$") else { return input }
        var out = ""
        var chars = Array(input)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            guard ch == "$" else { out.append(ch); i += 1; continue }
            // `$$` → literal `$`.
            if i + 1 < chars.count && chars[i + 1] == "$" {
                out.append("$"); i += 2; continue
            }
            if i + 1 < chars.count && chars[i + 1] == "{" {
                // Braced form: read to matching `}`.
                var j = i + 2
                var body = ""
                while j < chars.count && chars[j] != "}" { body.append(chars[j]); j += 1 }
                out += resolveBraced(body)
                i = (j < chars.count) ? j + 1 : j
            } else if i + 1 < chars.count && (chars[i + 1].isLetter || chars[i + 1] == "_") {
                // Bare `$VAR` form.
                var j = i + 1
                var name = ""
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") {
                    name.append(chars[j]); j += 1
                }
                out += environment[name] ?? ""
                i = j
            } else {
                out.append(ch); i += 1
            }
        }
        return out
    }

    private func resolveBraced(_ body: String) -> String {
        // `VAR:-default` / `VAR-default` / `VAR:?msg` / `VAR`.
        if let range = body.range(of: ":-") {
            let name = String(body[..<range.lowerBound])
            let def = String(body[range.upperBound...])
            let value = environment[name]
            return (value?.isEmpty == false) ? value! : def
        }
        if let range = body.range(of: "-") {
            let name = String(body[..<range.lowerBound])
            let def = String(body[range.upperBound...])
            return environment[name] ?? def
        }
        if let range = body.range(of: ":?") ?? body.range(of: "?") {
            let name = String(body[..<range.lowerBound])
            return environment[name] ?? ""
        }
        return environment[body] ?? ""
    }
}

extension String {
    /// Self if non-empty, else nil — trims optional-chaining of blank scalars.
    var nonEmpty: String? { isEmpty ? nil : self }
}
