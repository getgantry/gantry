import Foundation

/// A system property value as TOML holds it.
public enum AppleSystemPropertyValue: Sendable, Equatable, Hashable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    /// A value Gantry does not edit (an array or table), kept as its literal.
    case other(String)

    /// The value as the user sees and types it.
    public var display: String {
        switch self {
        case .string(let value): value
        case .integer(let value): String(value)
        case .number(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        case .other(let literal): literal
        }
    }

    /// The value as a TOML literal.
    public var tomlLiteral: String {
        switch self {
        case .string(let value): AppleContainerControl.tomlQuoted(value)
        case .integer(let value): String(value)
        case .number(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        case .other(let literal): literal
        }
    }
}

/// The type of a system property, which drives the editor and validation.
public enum AppleSystemPropertyKind: String, Sendable, CaseIterable {
    case bool
    /// A positive integer, e.g. a CPU count.
    case count
    /// A memory size such as `2048mb` or `4g`.
    case memory
    case string
    case imageReference
    case url
    case digest
    case domain
    case registryHost
    case cidrV4
    case cidrV6
    /// `rw`, `ro` or `none` (machine home directory mount).
    case homeMount
    /// Any whole number (a key without a schema that holds an integer).
    case integerValue
    /// Any number (a key without a schema that holds a float).
    case numberValue
    /// A key Gantry has no schema for: the type is taken from the value.
    case unknown

    /// The values a picker offers, or nil for a free-form value.
    public var choices: [String]? {
        switch self {
        case .bool: ["true", "false"]
        case .homeMount: ["rw", "ro", "none"]
        default: nil
        }
    }
}

/// One `section.key` system property: the value the services use now
/// (`container system property list`) and the value in the user's
/// `~/.config/container/config.toml`, which the services load at start.
public struct AppleSystemProperty: Sendable, Equatable, Identifiable {
    /// The dotted key, e.g. `build.cpus` or `plugin.foo.bar`.
    public var key: String
    public var kind: AppleSystemPropertyKind
    /// The value the running services report; nil when unset.
    public var effective: AppleSystemPropertyValue?
    /// The value in the user configuration file; nil when the user has not set it.
    public var user: AppleSystemPropertyValue?

    public var id: String { key }
    public var section: String { AppleContainerControl.splitPropertyKey(key).section }
    public var name: String { AppleContainerControl.splitPropertyKey(key).name }

    /// The user file sets a value the services have not loaded yet: a
    /// services restart applies it. The services report values in their
    /// own form (`4g` as `4gb`), so both sides are normalised first.
    public var isPendingRestart: Bool {
        guard let user else { return false }
        guard let effective else { return true }
        return !AppleContainerControl.propertyValuesMatch(user, effective, kind: kind)
    }

    public init(
        key: String,
        kind: AppleSystemPropertyKind,
        effective: AppleSystemPropertyValue? = nil,
        user: AppleSystemPropertyValue? = nil
    ) {
        self.key = key
        self.kind = kind
        self.effective = effective
        self.user = user
    }
}

extension AppleContainerControl {
    // MARK: - System properties

    /// Known keys and their types (apple/container 1.0+ `config.toml`
    /// reference, plus the machine plugin's `[machine]` table). Keys such as
    /// `dns.domain` that are unset by default appear only here.
    public static let propertySchema: [(key: String, kind: AppleSystemPropertyKind)] = [
        ("build.cpus", .count),
        ("build.memory", .memory),
        ("build.rosetta", .bool),
        ("build.image", .imageReference),
        ("container.cpus", .count),
        ("container.memory", .memory),
        ("dns.domain", .domain),
        ("kernel.binaryPath", .string),
        ("kernel.url", .url),
        ("kernel.digest", .digest),
        ("network.subnet", .cidrV4),
        ("network.subnetv6", .cidrV6),
        ("registry.domain", .registryHost),
        ("vminit.image", .imageReference),
        ("machine.cpus", .count),
        ("machine.memory", .memory),
        ("machine.homeMount", .homeMount),
        ("machine.virtualization", .bool)
    ]

    /// `~/.config/container/config.toml`, the file property edits go to.
    public static var userConfigFileURL: URL { configFileURL() }

    public static func propertyKind(for key: String) -> AppleSystemPropertyKind {
        propertySchema.first { $0.key == key }?.kind ?? .unknown
    }

    /// The effective properties merged with the user file and the schema.
    public static func listProperties(cliOverride: String? = nil) async throws -> [AppleSystemProperty] {
        let output = try await runContainer(["system", "property", "list", "--format", "json"], cliOverride: cliOverride)
        let userText = (try? String(contentsOf: configFileURL(), encoding: .utf8)) ?? ""
        return mergeProperties(effective: parsePropertyList(output), user: parseConfigTOML(userText))
    }

    /// Validates `raw` for `key` and writes it to the user configuration file.
    /// The services load the change at their next start.
    /// `kind` overrides the schema type, e.g. for a key the schema does not
    /// know but the services report with a type.
    @discardableResult
    public static func setUserProperty(
        _ key: String,
        to raw: String,
        kind: AppleSystemPropertyKind? = nil
    ) throws -> AppleSystemPropertyValue {
        try setUserProperty(key, to: raw, kind: kind, configURL: configFileURL())
    }

    @discardableResult
    static func setUserProperty(
        _ key: String,
        to raw: String,
        kind: AppleSystemPropertyKind? = nil,
        configURL: URL
    ) throws -> AppleSystemPropertyValue {
        let key = try validatedPropertyKey(key)
        let value = try validatedPropertyValue(raw, kind: kind ?? propertyKind(for: key))
        try writeConfig(at: configURL) { try updatedConfigTOML($0, key: key, value: value) }
        return value
    }

    /// Removes `key` from the user configuration file, so the services fall
    /// back to the package default at their next start.
    public static func clearUserProperty(_ key: String) throws {
        try clearUserProperty(key, configURL: configFileURL())
    }

    static func clearUserProperty(_ key: String, configURL: URL) throws {
        let key = try validatedPropertyKey(key)
        try writeConfig(at: configURL) { try updatedConfigTOML($0, key: key, value: nil) }
    }

    /// Rewrites the configuration file through `transform`. A symlinked file
    /// is written at its target and keeps its permissions; a missing file
    /// and folder are created. The write is atomic (temporary file + rename).
    static func writeConfig(at url: URL, _ transform: (String) throws -> String) throws {
        let target = resolvedConfigTarget(url)
        let manager = FileManager.default
        let folder = target.deletingLastPathComponent()
        if !manager.fileExists(atPath: folder.path) {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        var existing = ""
        var permissions: Int?
        if manager.fileExists(atPath: target.path) {
            // A file that cannot be read as text must not be replaced.
            existing = try String(contentsOf: target, encoding: .utf8)
            permissions = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? Int
        }
        let updated = try transform(existing)
        guard updated != existing else { return }
        let temporary = folder.appendingPathComponent(".\(target.lastPathComponent).gantry-\(UUID().uuidString)")
        try Data(updated.utf8).write(to: temporary, options: .withoutOverwriting)
        do {
            try manager.setAttributes([.posixPermissions: permissions ?? 0o644], ofItemAtPath: temporary.path)
            guard rename(temporary.path, target.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    /// Follows symbolic links to the real file, also when the link points
    /// at a file that does not exist yet.
    static func resolvedConfigTarget(_ url: URL) -> URL {
        var current = url.standardizedFileURL
        for _ in 0..<32 {
            let parent = current.deletingLastPathComponent().resolvingSymlinksInPath()
            current = parent.appendingPathComponent(current.lastPathComponent)
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else {
                return current
            }
            current = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : parent.appendingPathComponent(destination)
            current = current.standardizedFileURL
        }
        return current
    }

    static func mergeProperties(
        effective: [String: AppleSystemPropertyValue],
        user: [String: AppleSystemPropertyValue]
    ) -> [AppleSystemProperty] {
        // A table from a plugin (`[machine]`) is listed only when the
        // installed CLI reports it, so a package without the plugin does not
        // offer keys that would have no effect.
        let reportedSections = Set(effective.keys.map { splitPropertyKey($0).section })
            .union(user.keys.map { splitPropertyKey($0).section })
        let coreSections: Set<String> = ["build", "container", "dns", "kernel", "network", "registry", "vminit"]
        var keys = propertySchema.map(\.key).filter { key in
            let section = splitPropertyKey(key).section
            return coreSections.contains(section) || reportedSections.contains(section)
        }
        let known = Set(propertySchema.map(\.key))
        keys += Set(effective.keys).union(user.keys).subtracting(known).sorted()
        return keys.map { key in
            AppleSystemProperty(key: key, kind: propertyKind(for: key), effective: effective[key], user: user[key])
        }
    }

    /// Flattens `system property list --format json` into dotted keys.
    static func parsePropertyList(_ json: String) -> [String: AppleSystemPropertyValue] {
        guard let object = jsonObject(json) as? [String: Any] else { return [:] }
        var result: [String: AppleSystemPropertyValue] = [:]
        func walk(_ dictionary: [String: Any], prefix: String) {
            for (name, value) in dictionary {
                let key = prefix.isEmpty ? name : "\(prefix).\(name)"
                if let nested = value as? [String: Any] {
                    walk(nested, prefix: key)
                } else if let converted = propertyValue(fromJSON: value) {
                    result[key] = converted
                }
            }
        }
        walk(object, prefix: "")
        return result
    }

    private static func propertyValue(fromJSON value: Any) -> AppleSystemPropertyValue? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) { return .number(number.doubleValue) }
            return .integer(number.intValue)
        }
        if let string = value as? String { return .string(string) }
        if value is NSNull { return nil }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) {
            return .other(String(decoding: data, as: UTF8.self))
        }
        return nil
    }

    // MARK: - Comparison

    /// Whether the user value and the value the services report mean the
    /// same. The services print memory sizes as `<n><unit>b` (`4g` → `4gb`)
    /// and arrays as JSON, so those compare by meaning, not by text.
    static func propertyValuesMatch(
        _ user: AppleSystemPropertyValue,
        _ effective: AppleSystemPropertyValue,
        kind: AppleSystemPropertyKind
    ) -> Bool {
        switch (user, effective) {
        case let (.string(a), .string(b)) where kind == .memory:
            guard let lhs = memoryBytes(a), let rhs = memoryBytes(b) else { return a == b }
            return lhs == rhs
        case let (.integer(a), .number(b)), let (.number(b), .integer(a)):
            return Double(a) == b
        case let (.other(a), .other(b)):
            return a == b || canonicalTOMLJSON(a).map { $0 == canonicalJSON(b) } ?? false
        default:
            return user == effective
        }
    }

    /// The size in bytes of a memory value as the CLI parses it: a number and
    /// an optional `b`, `k`, `m`, `g`, `t` or `p` unit with `b` or `ib`.
    static func memoryBytes(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let match = value.wholeMatch(of: /([0-9.]+)\s*(([bkmgtp])(i?b)?)?/),
              let number = Double(match.1) else { return nil }
        let exponents: [Substring: Double] = ["b": 0, "k": 1, "m": 2, "g": 3, "t": 4, "p": 5]
        let exponent = match.3.flatMap { exponents[$0] } ?? 0
        return number * pow(1024, exponent)
    }

    private static func canonicalTOMLJSON(_ literal: String) -> String? {
        guard let document = try? ConfigTOMLDocument("v = " + literal),
              let value = document.entries.first?.value else { return nil }
        return serializedJSON(value.foundationObject)
    }

    private static func canonicalJSON(_ json: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) else {
            return nil
        }
        return serializedJSON(object)
    }

    private static func serializedJSON(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Validation

    /// Validates a typed value for `kind`, returning it in the TOML type the
    /// services expect.
    public static func validatedPropertyValue(_ raw: String, kind: AppleSystemPropertyKind) throws -> AppleSystemPropertyValue {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func fail(_ message: String) -> AppleSystemError { .invalidInput(message) }
        guard !value.isEmpty else { throw fail("Enter a value, or clear the property to use the default.") }
        guard !value.contains(where: \.isNewline) else { throw fail("A value cannot contain line breaks.") }
        switch kind {
        case .bool:
            switch value.lowercased() {
            case "true", "yes", "on", "1": return .bool(true)
            case "false", "no", "off", "0": return .bool(false)
            default: throw fail("Enter true or false.")
            }
        case .count:
            guard let number = Int(value), number > 0 else { throw fail("Enter a positive whole number.") }
            return .integer(number)
        case .memory:
            guard isValidMemorySize(value) else {
                throw fail("Enter a memory size such as 2048mb or 4g.")
            }
            return .string(value.lowercased())
        case .string:
            return .string(value)
        case .imageReference:
            guard !value.contains(where: \.isWhitespace) else { throw fail("An image reference cannot contain spaces.") }
            return .string(value)
        case .url:
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http", url.host != nil else {
                throw fail("Enter an http(s) URL.")
            }
            return .string(value)
        case .digest:
            guard isValidDigest(value) else { throw fail("The digest must have the form sha256:<64 hex digits>.") }
            return .string(value)
        case .domain:
            guard isValidDomainName(value) else { throw fail("Enter a domain name: letters, digits, dots and hyphens.") }
            return .string(value)
        case .registryHost:
            guard isValidRegistryServer(value) else { throw fail("Enter a registry host name, for example docker.io.") }
            return .string(value)
        case .cidrV4:
            guard isValidCIDR(value, v6: false) else { throw fail("Enter an IPv4 subnet such as 192.168.100.0/24.") }
            return .string(value)
        case .cidrV6:
            guard isValidCIDR(value, v6: true) else { throw fail("Enter an IPv6 subnet such as fd00:abcd::/64.") }
            return .string(value)
        case .homeMount:
            guard let choices = kind.choices, choices.contains(value.lowercased()) else {
                throw fail("Enter rw, ro or none.")
            }
            return .string(value.lowercased())
        case .integerValue:
            guard let number = Int(value) else { throw fail("Enter a whole number.") }
            return .integer(number)
        case .numberValue:
            guard let number = Double(value), number.isFinite else { throw fail("Enter a number.") }
            return .number(number)
        case .unknown:
            if let number = Int(value) { return .integer(number) }
            if value == "true" || value == "false" { return .bool(value == "true") }
            return .string(value)
        }
    }

    /// An IPv4 (`a.b.c.d/n`, n ≤ 32) or IPv6 (`addr/n`, n ≤ 128) subnet.
    public static func isValidCIDR(_ value: String, v6: Bool) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), !parts[1].isEmpty,
              parts[1].allSatisfy(\.isNumber) else { return false }
        let address = String(parts[0])
        if v6 {
            var buffer = in6_addr()
            return prefix >= 0 && prefix <= 128 && inet_pton(AF_INET6, address, &buffer) == 1
        }
        var buffer = in_addr()
        return prefix >= 0 && prefix <= 32 && address.split(separator: ".").count == 4
            && inet_pton(AF_INET, address, &buffer) == 1
    }

    // MARK: - TOML

    /// Splits `a.b.c` into the table `a.b` and the key `c`.
    public static func splitPropertyKey(_ key: String) -> (section: String, name: String) {
        guard let dot = key.lastIndex(of: ".") else { return ("", key) }
        return (String(key[..<dot]), String(key[key.index(after: dot)...]))
    }

    static func tomlQuoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    /// Reads the flat `table.key = value` pairs of a TOML file: tables,
    /// dotted keys and inline tables flatten into dotted keys. Arrays and
    /// dates are kept as `.other` literals; pairs under `[[array]]` tables
    /// are skipped. A file that does not parse gives no values.
    static func parseConfigTOML(_ toml: String) -> [String: AppleSystemPropertyValue] {
        guard let document = try? ConfigTOMLDocument(toml) else { return [:] }
        var result: [String: AppleSystemPropertyValue] = [:]
        for entry in document.entries where !entry.inArrayOfTables {
            let key = entry.path.joined(separator: ".")
            switch entry.value {
            case .string(let value): result[key] = .string(value)
            case .integer(let value): result[key] = .integer(value)
            case .float(let value): result[key] = .number(value)
            case .bool(let value): result[key] = .bool(value)
            case .table: continue
            case .datetime, .array:
                result[key] = .other(String(decoding: document.bytes[entry.valueRange], as: UTF8.self))
            }
        }
        return result
    }

    /// Returns `toml` with `key` set to `value` (or removed when nil). Every
    /// other byte of the file stays as it was. Throws when the file is not
    /// valid TOML or the change cannot be made safely: the result is parsed
    /// again and compared with the input before it is returned.
    static func updatedConfigTOML(_ toml: String, key: String, value: AppleSystemPropertyValue?) throws -> String {
        try ConfigTOMLDocument.edit(
            toml,
            path: key.split(separator: ".", omittingEmptySubsequences: false).map(String.init),
            literal: value?.tomlLiteral
        )
    }

    /// A `section.key` (or deeper) property key of bare TOML key parts, so a
    /// key cannot break out of its line.
    public static func isValidPropertyKey(_ key: String) -> Bool {
        key.wholeMatch(of: /[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+/) != nil
    }

    static func validatedPropertyKey(_ key: String) throws -> String {
        guard isValidPropertyKey(key) else {
            throw AppleSystemError.invalidInput("“\(key)” is not a valid property key. Use a dotted name such as build.cpus.")
        }
        return key
    }
}
