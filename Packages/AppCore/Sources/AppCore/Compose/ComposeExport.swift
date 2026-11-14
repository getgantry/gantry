import Foundation
import Yams
import DockerKit

// MARK: - Public types

/// One container to export: the raw inspect bodies Gantry already fetches for
/// the Inspect tab, and what kind of host they came from.
public struct ComposeExportSource: Sendable, Equatable {
    /// `GET /containers/{id}/json`. On apple/container hosts the body also
    /// carries the original CLI object under `AppleContainer`.
    public var containerInspect: Data
    /// `GET /images/{id}/json` of the container's image, or nil when the image
    /// could not be inspected. Used to leave out the image defaults.
    public var imageInspect: Data?
    public var isAppleContainer: Bool
    /// The host is reached over SSH, so bind sources are remote paths.
    public var isRemoteHost: Bool

    public init(containerInspect: Data, imageInspect: Data? = nil, isAppleContainer: Bool = false, isRemoteHost: Bool = false) {
        self.containerInspect = containerInspect
        self.imageInspect = imageInspect
        self.isAppleContainer = isAppleContainer
        self.isRemoteHost = isRemoteHost
    }
}

/// An environment variable whose value looks like a secret.
public struct ComposeExportSecret: Hashable, Sendable, Identifiable {
    public var service: String
    public var variable: String
    public var id: String { service + "/" + variable }

    public init(service: String, variable: String) {
        self.service = service
        self.variable = variable
    }
}

/// A setting that the Compose file cannot express, or cannot copy exactly.
public struct ComposeExportWarning: Hashable, Sendable, Identifiable {
    public var service: String
    public var message: String
    public var id: String { service + "\n" + message }

    public init(service: String, message: String) {
        self.service = service
        self.message = message
    }
}

public struct ComposeExportOptions: Sendable, Equatable {
    /// Masked variables whose real value goes into the file.
    public var includedSecrets: Set<ComposeExportSecret>

    public init(includedSecrets: Set<ComposeExportSecret> = []) {
        self.includedSecrets = includedSecrets
    }
}

public struct ComposeExportResult: Sendable, Equatable {
    public var yaml: String
    public var warnings: [ComposeExportWarning]
    /// Every secret-like variable, masked or included, in file order.
    public var secrets: [ComposeExportSecret]
    /// The file holds at least one secret value, so it is saved as `0600`.
    public var includesSecretValues: Bool
    public var serviceNames: [String]
}

public enum ComposeExportError: Error, LocalizedError, Equatable {
    case invalidInspect
    case noContainers

    public var errorDescription: String? {
        switch self {
        case .invalidInspect:
            String(localized: "Gantry could not read the inspect data of the container.", bundle: .module)
        case .noContainers:
            String(localized: "Select one or more containers to export.", bundle: .module)
        }
    }
}

// MARK: - Exporter

/// Makes a Compose file from the inspect data of running containers.
public enum ComposeExporter {
    public static func export(
        _ sources: [ComposeExportSource],
        options: ComposeExportOptions = ComposeExportOptions()
    ) throws -> ComposeExportResult {
        guard !sources.isEmpty else { throw ComposeExportError.noContainers }
        var drafts: [ServiceDraft] = []
        for source in sources {
            guard let root = try? JSONSerialization.jsonObject(with: source.containerInspect) as? [String: Any] else {
                throw ComposeExportError.invalidInspect
            }
            let image = ImageConfig(inspectJSON: source.imageInspect)
            if source.isAppleContainer, let apple = root["AppleContainer"] as? [String: Any] {
                drafts.append(ServiceDraft(apple: apple, docker: root, image: image))
            } else {
                drafts.append(ServiceDraft(docker: root, image: image, isRemoteHost: source.isRemoteHost))
            }
        }
        return assemble(drafts, options: options)
    }

    // MARK: Assembly

    static func assemble(_ input: [ServiceDraft], options: ComposeExportOptions) -> ComposeExportResult {
        var drafts = input
        assignServiceNames(&drafts)
        resolveReferences(&drafts)

        var warnings: [ComposeExportWarning] = []
        var secrets: [ComposeExportSecret] = []
        var includesSecretValues = false
        var services: [(String, YValue)] = []
        var networks: [String] = []
        var volumes: [String] = []

        for draft in drafts {
            var fields = draft.fields
            var environment: [(String, YValue)] = []
            for (key, value) in draft.environment {
                // A variable that Gantry filled from a Keychain secret: the
                // file holds the reference, never the value.
                if let name = draft.keychainSecrets[key] {
                    environment.append((key, .str(EnvSecrets.referenceText(name))))
                    continue
                }
                guard SecretDetector.isSecret(name: key, value: value) else {
                    environment.append((key, .str(value)))
                    continue
                }
                let secret = ComposeExportSecret(service: draft.serviceName, variable: key)
                secrets.append(secret)
                if options.includedSecrets.contains(secret) {
                    includesSecretValues = true
                    environment.append((key, .str(value)))
                } else if SecretDetector.isVariableName(key) {
                    environment.append((key, .raw("${\(key)}")))
                } else {
                    warnings.append(ComposeExportWarning(service: draft.serviceName, message: String(
                        localized: "The file leaves out the secret variable \(key). Compose cannot read a variable with this name.",
                        bundle: .module)))
                }
            }
            if !environment.isEmpty { fields["environment"] = .map(environment) }
            for network in draft.networkNames where !networks.contains(network) { networks.append(network) }
            for volume in draft.volumeNames where !volumes.contains(volume) { volumes.append(volume) }
            warnings += draft.warnings.map { ComposeExportWarning(service: draft.serviceName, message: $0) }
            services.append((draft.serviceName, .map(ServiceDraft.ordered(fields))))
        }

        var root: [(String, YValue)] = []
        let projects = Set(drafts.map { $0.composeProject ?? "" })
        if projects.count == 1, let project = projects.first, !project.isEmpty {
            root.append(("name", .str(project)))
        }
        root.append(("services", .map(services)))
        let external: YValue = .map([("external", .bool(true))])
        if !networks.isEmpty { root.append(("networks", .map(networks.map { ($0, external) }))) }
        if !volumes.isEmpty { root.append(("volumes", .map(volumes.map { ($0, external) }))) }

        let yaml = (try? Yams.serialize(node: YValue.map(root).node, indent: 2, width: -1, allowUnicode: true)) ?? ""
        return ComposeExportResult(
            yaml: yaml,
            warnings: warnings,
            secrets: secrets,
            includesSecretValues: includesSecretValues,
            serviceNames: drafts.map(\.serviceName)
        )
    }

    /// Compose service names from the Compose labels, else from the container
    /// name; a repeated name gets `-2`, `-3`.
    static func assignServiceNames(_ drafts: inout [ServiceDraft]) {
        var taken: Set<String> = []
        for index in drafts.indices {
            let base = serviceName(from: drafts[index].preferredName)
            var name = base
            var counter = 2
            while taken.contains(name) {
                name = "\(base)-\(counter)"
                counter += 1
            }
            taken.insert(name)
            drafts[index].serviceName = name
        }
    }

    /// Lowercase letters, digits, `_` and `-`, starting with a letter or digit.
    static func serviceName(from raw: String) -> String {
        var result = ""
        for character in raw.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber || character == "_" || character == "-" {
                result.append(character)
            } else if character == "." || character == " " {
                result.append("-")
            }
        }
        while let first = result.first, first == "-" || first == "_" { result.removeFirst() }
        return result.isEmpty ? "service" : result
    }

    /// `network_mode: container:<id>` and Compose `depends_on` labels that
    /// point at another exported container become service references.
    static func resolveReferences(_ drafts: inout [ServiceDraft]) {
        let lookup = drafts.map { (id: $0.containerID, name: $0.containerName ?? $0.preferredName, service: $0.serviceName) }
        func service(for reference: String) -> String? {
            lookup.first { item in
                item.name == reference || item.id == reference
                    || (reference.count >= 12 && item.id.hasPrefix(reference))
            }?.service
        }
        for index in drafts.indices {
            if let mode = drafts[index].networkMode {
                if mode.hasPrefix("container:") {
                    let target = String(mode.dropFirst("container:".count))
                    if let name = service(for: target) {
                        drafts[index].fields["network_mode"] = .str("service:" + name)
                    } else {
                        drafts[index].fields["network_mode"] = .str(mode)
                        drafts[index].warnings.append(String(
                            localized: "The container uses the network of the container \(target), which is not in the export.",
                            bundle: .module))
                    }
                } else {
                    drafts[index].fields["network_mode"] = .str(mode)
                }
            }
            let project = drafts[index].composeProject
            let dependencies = drafts[index].composeDependsOn.compactMap { dependency in
                drafts.first { $0.composeProject == project && $0.composeService == dependency }?.serviceName
            }
            if !dependencies.isEmpty { drafts[index].fields["depends_on"] = .list(dependencies.map { .str($0) }) }
        }
    }
}

// MARK: - Service draft

/// The Compose service of one container before the names and references of
/// the whole export are known.
struct ServiceDraft {
    var containerID = ""
    var containerName: String?
    /// The service label of a Compose container, else the container name.
    var preferredName = ""
    var serviceName = ""
    var composeProject: String?
    var composeService: String?
    var composeDependsOn: [String] = []
    /// Service keys except `environment`, `network_mode` and `depends_on`.
    var fields: [String: YValue] = [:]
    var environment: [(String, String)] = []
    /// Variable → Keychain secret name, from Gantry's secret label.
    var keychainSecrets: [String: String] = [:]
    var networkMode: String?
    var networkNames: [String] = []
    var volumeNames: [String] = []
    var warnings: [String] = []

    /// The key order of a service in the file. Other keys follow, sorted.
    static let keyOrder = [
        "image", "container_name", "platform", "entrypoint", "command", "working_dir", "user",
        "hostname", "domainname", "environment", "ports", "volumes", "volumes_from", "tmpfs",
        "network_mode", "networks", "depends_on", "restart", "healthcheck", "labels", "deploy"
    ]

    static func ordered(_ fields: [String: YValue]) -> [(String, YValue)] {
        let known = keyOrder.compactMap { key in fields[key].map { (key, $0) } }
        let rest = fields.keys.filter { !keyOrder.contains($0) }.sorted().map { ($0, fields[$0]!) }
        return known + rest
    }

    /// Records the Compose labels and removes them, with Gantry's own labels.
    mutating func setLabels(_ all: [String: String], image: [String: String]) {
        keychainSecrets = SecretEnvLabel.references(in: all)
        composeProject = all["com.docker.compose.project"]?.nonEmptyValue
        composeService = all["com.docker.compose.service"]?.nonEmptyValue
        composeDependsOn = (all["com.docker.compose.depends_on"] ?? "")
            .split(separator: ",")
            .compactMap { $0.split(separator: ":").first.map(String.init) }
            .filter { !$0.isEmpty }
        if let composeService { preferredName = composeService }
        let hidden = ContainerRecipe.internalLabelKeys
        let labels = all.keys.sorted()
            .filter { !$0.hasPrefix("com.docker.compose.") && !hidden.contains($0) && image[$0] != all[$0] }
            .map { ($0, YValue.str(all[$0] ?? "")) }
        if !labels.isEmpty { fields["labels"] = .map(labels) }
    }

    /// Environment entries of the container that the image does not set.
    mutating func setEnvironment(_ entries: [String], image: [String]) {
        for entry in entries where !image.contains(entry) {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            environment.append((String(entry[..<eq]), String(entry[entry.index(after: eq)...])))
        }
    }

    mutating func setList(_ key: String, _ values: [String]) {
        let clean = values.filter { !$0.isEmpty }
        if !clean.isEmpty { fields[key] = .list(clean.map { .str($0) }) }
    }

    mutating func setString(_ key: String, _ value: String?) {
        if let value, !value.isEmpty { fields[key] = .str(value) }
    }

    /// `deploy.resources` from CPU, memory and pids values.
    mutating func setResources(cpus: String?, memory: Int64?, reservation: Int64? = nil, pids: Int64? = nil) {
        var limits: [(String, YValue)] = []
        if let cpus { limits.append(("cpus", .str(cpus))) }
        if let memory, memory > 0 { limits.append(("memory", .str(ContainerRecipe.memoryText(bytes: memory)))) }
        if let pids, pids > 0 { limits.append(("pids", .int(pids))) }
        var resources: [(String, YValue)] = []
        if !limits.isEmpty { resources.append(("limits", .map(limits))) }
        if let reservation, reservation > 0 {
            resources.append(("reservations", .map([("memory", .str(ContainerRecipe.memoryText(bytes: reservation)))])))
        }
        if !resources.isEmpty { fields["deploy"] = .map([("resources", .map(resources))]) }
    }

    /// Short volume syntax when it is safe, else the long form.
    mutating func addVolume(type: String, source: String, target: String, readOnly: Bool, modes: [String] = []) {
        var list = fields["volumes"]?.listValue ?? []
        if source.contains(":") || target.contains(":") {
            var entry: [(String, YValue)] = [("type", .str(type)), ("source", .str(source)), ("target", .str(target))]
            if readOnly { entry.append(("read_only", .bool(true))) }
            list.append(.map(entry))
        } else {
            let flags = (readOnly ? ["ro"] : []) + modes
            list.append(.str(([source, target] + (flags.isEmpty ? [] : [flags.joined(separator: ",")])).joined(separator: ":")))
        }
        fields["volumes"] = .list(list)
        if type == "volume", !volumeNames.contains(source) { volumeNames.append(source) }
    }

    /// A warning for a CLI option that has no Compose key.
    static func noSetting(_ option: String) -> String {
        String(localized: "Compose has no setting for \(option). The file leaves it out.", bundle: .module)
    }

    static func mountLeftOut(target: String, type: String) -> String {
        String(localized: "The file leaves out the mount at \(target) (type \(type)).", bundle: .module)
    }

    mutating func addAnonymousVolume(target: String) {
        var list = fields["volumes"]?.listValue ?? []
        list.append(.str(target))
        fields["volumes"] = .list(list)
        warnings.append(String(
            localized: "The anonymous volume at \(target) becomes a new, empty volume. Its data is not copied.",
            bundle: .module))
    }

    /// The process of the container, without what the image starts anyway.
    /// A new entrypoint clears the image command, so the command goes too.
    mutating func setProcess(entrypoint: [String], command: [String], image: ImageConfig?) {
        if let image, entrypoint == image.entrypoint {
            if command != image.cmd { fields["command"] = .list(command.map { .str($0) }) }
            return
        }
        if !entrypoint.isEmpty { fields["entrypoint"] = .list(entrypoint.map { .str($0) }) }
        if !command.isEmpty { fields["command"] = .list(command.map { .str($0) }) }
        if let image, entrypoint.isEmpty, !image.entrypoint.isEmpty {
            // The container cleared the entrypoint of the image.
            fields["entrypoint"] = .list([])
        }
    }

    mutating func addImageWarnings(image reference: String, imageConfig: ImageConfig?) {
        let bare = reference.hasPrefix("sha256:") ? String(reference.dropFirst(7)) : reference
        if bare.count == 64, bare.allSatisfy(\.isHexDigit) {
            warnings.append(String(
                localized: "The image is known only by its ID. Replace it with a name and tag that a registry has.",
                bundle: .module))
        }
        if imageConfig == nil {
            warnings.append(String(
                localized: "Gantry could not inspect the image, so the file also repeats the image defaults.",
                bundle: .module))
        }
    }
}

// MARK: - Image config

/// The `Config` of an image inspect body: the defaults that a container
/// inherits and that the file leaves out.
struct ImageConfig: Equatable {
    var env: [String] = []
    var cmd: [String] = []
    var entrypoint: [String] = []
    var workingDir = ""
    var user = ""
    var labels: [String: String] = [:]
    var stopSignal = ""
    var healthcheck: NSDictionary?

    init?(inspectJSON data: Data?) {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["Config"] as? [String: Any] else { return nil }
        env = config["Env"] as? [String] ?? []
        cmd = config["Cmd"] as? [String] ?? []
        entrypoint = config["Entrypoint"] as? [String] ?? []
        workingDir = config["WorkingDir"] as? String ?? ""
        user = config["User"] as? String ?? ""
        labels = config["Labels"] as? [String: String] ?? [:]
        stopSignal = config["StopSignal"] as? String ?? ""
        healthcheck = (config["Healthcheck"] as? [String: Any]).map { $0 as NSDictionary }
    }
}

// MARK: - Secrets

enum SecretDetector {
    private static let urlPassword = try! NSRegularExpression(pattern: #"://[^/\s:@]+:[^/\s@]+@"#)

    /// A secret-named variable with a value, a random-looking value, or a
    /// URL with a password.
    static func isSecret(name: String, value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if SecretRedactor.isSecretName(name) || SecretRedactor.looksRandom(value) { return true }
        let range = NSRange(value.startIndex..., in: value)
        return urlPassword.firstMatch(in: value, range: range) != nil
    }

    /// Whether `${name}` is valid Compose interpolation.
    static func isVariableName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}

// MARK: - YAML values

/// A YAML value with the quoting rules of the export.
indirect enum YValue {
    /// A string value. `$` is escaped as `$$` so that Compose keeps it.
    case str(String)
    /// A string written as is: a `${NAME}` reference that Gantry made.
    case raw(String)
    case bool(Bool)
    case int(Int64)
    case list([YValue])
    case map([(String, YValue)])

    var listValue: [YValue]? {
        if case .list(let items) = self { return items }
        return nil
    }

    var node: Node {
        switch self {
        case .str(let text):
            return Self.scalar(text.replacingOccurrences(of: "$", with: "$$"))
        case .raw(let text):
            return Self.scalar(text)
        case .bool(let value):
            return .scalar(.init(value ? "true" : "false", Tag(.bool), .plain))
        case .int(let value):
            return .scalar(.init(String(value), Tag(.int), .plain))
        case .list(let items):
            return .sequence(.init(items.map(\.node), Tag(.seq), items.isEmpty ? .flow : .block))
        case .map(let pairs):
            return .mapping(.init(pairs.map { (Self.scalar($0.0), $0.1.node) }, Tag(.map), pairs.isEmpty ? .flow : .block))
        }
    }

    /// Plain when no YAML reader can take the text as another type, else
    /// double-quoted.
    static func scalar(_ text: String) -> Node {
        .scalar(.init(text, Tag(.str), isPlainSafe(text) ? .plain : .doubleQuoted))
    }

    private static let keywords: Set<String> = [
        "y", "n", "yes", "no", "on", "off", "true", "false", "null", "~"
    ]

    static func isPlainSafe(_ text: String) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter || first == "/" || first == "_" else { return false }
        guard !keywords.contains(text.lowercased()), !text.hasSuffix(":") else { return false }
        if text.contains(": ") || text.contains(" #") || text.hasSuffix(" ") { return false }
        return text.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || "_-./:@+=,${} ".contains(character))
        }
    }
}

extension String {
    fileprivate var nonEmptyValue: String? { isEmpty ? nil : self }
}

// MARK: - Durations and sizes

enum ComposeExportFormat {
    /// A Compose duration (`1m30s`, `500ms`) for nanoseconds.
    static func duration(nanoseconds: Int64) -> String {
        guard nanoseconds > 0 else { return "0s" }
        var rest = nanoseconds
        var parts = ""
        let units: [(String, Int64)] = [
            ("h", 3_600_000_000_000), ("m", 60_000_000_000), ("s", 1_000_000_000), ("ms", 1_000_000), ("us", 1_000)
        ]
        for (unit, size) in units where rest >= size {
            parts += "\(rest / size)\(unit)"
            rest %= size
        }
        return parts.isEmpty ? "\(nanoseconds)ns" : parts
    }

    /// A port entry: `[ip:]host:container[/proto]`, ranges when `count > 1`.
    static func port(hostIP: String, host: String, container: String, proto: String) -> String {
        var text = ""
        let ip = ["0.0.0.0", "::", ""].contains(hostIP) ? "" : hostIP
        if !ip.isEmpty { text += (ip.contains(":") ? "[\(ip)]" : ip) + ":" }
        if !host.isEmpty { text += host + ":" } else if !ip.isEmpty { text += ":" }
        text += container
        if !proto.isEmpty, proto.lowercased() != "tcp" { text += "/" + proto.lowercased() }
        return text
    }
}

// MARK: - Writing

public enum ComposeExportWriter {
    /// Writes the YAML to `url`. A file with a secret value is readable only
    /// by the user (`0600`); other files get `0644`. The file is made with
    /// its mode in a temporary file next to `url`, then moved in place, so a
    /// secret is never in a file that others can read.
    public static func write(_ result: ComposeExportResult, to url: URL) throws {
        let mode: mode_t = result.includesSecretValues ? 0o600 : 0o644
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, mode)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(result.yaml.utf8))
            try handle.close()
            // `open` applies the umask; set the exact mode.
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: temporary.path)
            guard rename(temporary.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
