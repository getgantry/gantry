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
    /// services restart applies it.
    public var isPendingRestart: Bool {
        guard let user else { return false }
        return user != effective
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
    @discardableResult
    public static func setUserProperty(_ key: String, to raw: String) throws -> AppleSystemPropertyValue {
        let value = try validatedPropertyValue(raw, kind: propertyKind(for: key))
        try writeConfig { updatedConfigTOML($0, key: key, value: value) }
        return value
    }

    /// Removes `key` from the user configuration file, so the services fall
    /// back to the package default at their next start.
    public static func clearUserProperty(_ key: String) throws {
        try writeConfig { updatedConfigTOML($0, key: key, value: nil) }
    }

    private static func writeConfig(_ transform: (String) throws -> String) throws {
        let url = configFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try transform(existing).write(to: url, atomically: true, encoding: .utf8)
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

    /// Reads the flat `table.key = value` pairs of a TOML file. Supports the
    /// subset `config.toml` uses: `[table]` and `[a.b]` headers, bare or
    /// quoted keys, strings, integers, floats and booleans. Other values are
    /// kept as `.other` literals.
    static func parseConfigTOML(_ toml: String) -> [String: AppleSystemPropertyValue] {
        var result: [String: AppleSystemPropertyValue] = [:]
        var section = ""
        for raw in toml.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let header = tableHeader(line) {
                section = header
                continue
            }
            guard let (name, literal) = keyValue(line) else { continue }
            let key = section.isEmpty ? name : "\(section).\(name)"
            result[key] = parseTOMLValue(literal)
        }
        return result
    }

    /// Returns `toml` with `key` set to `value` (or removed when nil). Every
    /// other line, comment and table stays as it was.
    static func updatedConfigTOML(_ toml: String, key: String, value: AppleSystemPropertyValue?) -> String {
        let (section, name) = splitPropertyKey(key)
        var lines = toml.isEmpty ? [] : toml.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        var current = ""
        var headerIndex: Int?
        var lastInSection: Int?
        var keyIndex: Int?
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let header = tableHeader(line) {
                current = header
                if header == section {
                    headerIndex = index
                    lastInSection = index
                }
                continue
            }
            guard current == section else { continue }
            if section.isEmpty, headerIndex == nil { lastInSection = index }
            if !line.isEmpty, !line.hasPrefix("#") { lastInSection = index }
            if let (lineKey, _) = keyValue(line), lineKey == name { keyIndex = index }
        }

        let newLine = value.map { "\(tomlKey(name)) = \($0.tomlLiteral)" }
        if let keyIndex {
            if let newLine { lines[keyIndex] = newLine } else { lines.remove(at: keyIndex) }
        } else if let newLine {
            if section.isEmpty {
                // Top-level keys must come before the first table.
                let firstTable = lines.firstIndex { tableHeader($0.trimmingCharacters(in: .whitespaces)) != nil }
                lines.insert(newLine, at: firstTable ?? lines.count)
            } else if let lastInSection {
                lines.insert(newLine, at: lastInSection + 1)
            } else {
                if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
                lines.append("[\(section)]")
                lines.append(newLine)
            }
        }

        var result = lines.joined(separator: "\n")
        if !result.isEmpty { result += "\n" }
        return result
    }

    private static func tomlKey(_ name: String) -> String {
        name.wholeMatch(of: /[A-Za-z0-9_-]+/) != nil ? name : tomlQuoted(name)
    }

    /// The table name of a `[table]` header line (not `[[array]]`).
    private static func tableHeader(_ line: String) -> String? {
        guard line.hasPrefix("["), !line.hasPrefix("[[") else { return nil }
        let body = stripComment(line)
        guard body.hasSuffix("]") else { return nil }
        return body.dropFirst().dropLast()
            .split(separator: ".")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .joined(separator: ".")
    }

    /// Splits `key = value` (value without a trailing comment).
    private static func keyValue(_ line: String) -> (String, String)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !key.isEmpty else { return nil }
        let value = stripComment(String(line[line.index(after: equals)...]))
        return (key, value)
    }

    /// Drops a `# comment` that is outside a quoted string.
    private static func stripComment(_ text: String) -> String {
        var quote: Character?
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if escaped { escaped = false; continue }
            if quote == "\"", character == "\\" { escaped = true; continue }
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return text[..<index].trimmingCharacters(in: .whitespaces)
            }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func parseTOMLValue(_ literal: String) -> AppleSystemPropertyValue {
        if literal == "true" { return .bool(true) }
        if literal == "false" { return .bool(false) }
        if literal.hasPrefix("\""), literal.hasSuffix("\""), literal.count >= 2 {
            return .string(unescapeTOML(String(literal.dropFirst().dropLast())))
        }
        if literal.hasPrefix("'"), literal.hasSuffix("'"), literal.count >= 2 {
            return .string(String(literal.dropFirst().dropLast()))
        }
        let digits = literal.replacingOccurrences(of: "_", with: "")
        if let integer = Int(digits) { return .integer(integer) }
        if let number = Double(digits) { return .number(number) }
        return .other(literal)
    }

    private static func unescapeTOML(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                result.append(character)
                continue
            }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case "u", "U":
                let count = next == "u" ? 4 : 8
                var hex = ""
                for _ in 0..<count { if let digit = iterator.next() { hex.append(digit) } }
                if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                }
            default:
                result.append("\\")
                result.append(next)
            }
        }
        return result
    }
}
