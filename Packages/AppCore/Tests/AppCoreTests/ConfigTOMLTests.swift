import Foundation
import Testing
@testable import AppCore

/// The `config.toml` reader and editor: each input that the old line-based
/// editor corrupted, round trips, refused edits, and the file write
/// (symlinks, permissions). All files are temporary.
@Suite struct ConfigTOMLTests {
    typealias C = AppleContainerControl

    // MARK: - Inputs the old editor corrupted

    @Test func editsDottedKeys() throws {
        let toml = "build.cpus = 4\nbuild.rosetta = true\n"
        #expect(C.parseConfigTOML(toml)["build.cpus"] == .integer(4))
        #expect(try C.updatedConfigTOML(toml, key: "build.cpus", value: .integer(2)) == "build.cpus = 2\nbuild.rosetta = true\n")
        #expect(try C.updatedConfigTOML(toml, key: "build.cpus", value: nil) == "build.rosetta = true\n")
        let added = try C.updatedConfigTOML(toml, key: "build.memory", value: .string("4g"))
        #expect(added == "build.cpus = 4\nbuild.rosetta = true\nbuild.memory = \"4g\"\n")
        #expect(C.parseConfigTOML(added)["build.memory"] == .string("4g"))
    }

    @Test func editsDottedKeysUnderAHeader() throws {
        let toml = "[plugin]\nfoo.bar = 1\n\n[dns]\ndomain = \"x\"\n"
        let added = try C.updatedConfigTOML(toml, key: "plugin.foo.baz", value: .integer(2))
        #expect(added == "[plugin]\nfoo.bar = 1\nfoo.baz = 2\n\n[dns]\ndomain = \"x\"\n")
    }

    @Test func editsInlineTables() throws {
        let toml = "build = { cpus = 4, rosetta = true } # inline\n"
        #expect(C.parseConfigTOML(toml)["build.cpus"] == .integer(4))
        #expect(try C.updatedConfigTOML(toml, key: "build.cpus", value: .integer(8))
            == "build = { cpus = 8, rosetta = true } # inline\n")
        // Adding to or removing from an inline table is refused.
        #expect(throws: ConfigTOMLError.self) { try C.updatedConfigTOML(toml, key: "build.memory", value: .string("4g")) }
        #expect(throws: ConfigTOMLError.self) { try C.updatedConfigTOML(toml, key: "build.cpus", value: nil) }
        // A header for the table would redefine it: refused too.
        let nested = "[a]\nb = { c = 1 }\n"
        #expect(throws: ConfigTOMLError.self) { try C.updatedConfigTOML(nested, key: "a.b.d", value: .integer(2)) }
    }

    @Test func keepsCRLF() throws {
        let toml = "[build]\r\ncpus = 4\r\n"
        #expect(C.parseConfigTOML(toml)["build.cpus"] == .integer(4))
        #expect(try C.updatedConfigTOML(toml, key: "build.cpus", value: .integer(2)) == "[build]\r\ncpus = 2\r\n")
        #expect(try C.updatedConfigTOML(toml, key: "build.memory", value: .string("4g"))
            == "[build]\r\ncpus = 4\r\nmemory = \"4g\"\r\n")
        #expect(try C.updatedConfigTOML(toml, key: "dns.domain", value: .string("test"))
            == "[build]\r\ncpus = 4\r\n\r\n[dns]\r\ndomain = \"test\"\r\n")
        #expect(try C.updatedConfigTOML(toml, key: "build.cpus", value: nil) == "[build]\r\n")
    }

    @Test func skipsMultilineArrays() throws {
        let toml = """
        [dns]
        servers = [
        ["1.1.1.1"],
          [ "8.8.8.8" ], # second
        ]
        [build]
        cpus = 1

        """
        let values = C.parseConfigTOML(toml)
        #expect(values["build.cpus"] == .integer(1))
        #expect(values["dns.servers"] != nil)
        let added = try C.updatedConfigTOML(toml, key: "dns.domain", value: .string("test"))
        #expect(added == toml.replacingOccurrences(of: "]\n[build]", with: "]\ndomain = \"test\"\n[build]"))
        // Overwriting an array is refused; removing it takes all its lines.
        #expect(throws: ConfigTOMLError.self) { try C.updatedConfigTOML(toml, key: "dns.servers", value: .string("x")) }
        #expect(try C.updatedConfigTOML(toml, key: "dns.servers", value: nil) == "[dns]\n[build]\ncpus = 1\n")
    }

    @Test func ignoresHeadersInCommentsAndStrings() throws {
        let toml = """
        # [build]
        [kernel]
        note = \"\"\"
        [build]
        cpus = 9
        \"\"\"
        raw = '''
        [dns]'''
        url = "https://x/#[build]" # [build]

        """
        let values = C.parseConfigTOML(toml)
        #expect(values["build.cpus"] == nil)
        #expect(values["kernel.note"] == .string("[build]\ncpus = 9\n"))
        #expect(values["kernel.raw"] == .string("[dns]"))
        #expect(values["kernel.url"] == .string("https://x/#[build]"))
        let added = try C.updatedConfigTOML(toml, key: "build.cpus", value: .integer(2))
        #expect(added == toml + "\n[build]\ncpus = 2\n")
        let url = try C.updatedConfigTOML(toml, key: "kernel.url", value: .string("https://y/k"))
        #expect(url == toml.replacingOccurrences(of: "\"https://x/#[build]\"", with: "\"https://y/k\""))
    }

    @Test func handlesQuotedKeysAndHeaders() throws {
        let toml = "[\"build\"]\n\"cpus\" = 4\n'memory' = \"2g\"\n"
        #expect(C.parseConfigTOML(toml)["build.cpus"] == .integer(4))
        #expect(try C.updatedConfigTOML(toml, key: "build.cpus", value: .integer(6))
            == "[\"build\"]\n\"cpus\" = 6\n'memory' = \"2g\"\n")
        #expect(try C.updatedConfigTOML(toml, key: "build.memory", value: nil) == "[\"build\"]\n\"cpus\" = 4\n")
        let spaced = "[ build . sub ]\nx = 1\n"
        #expect(C.parseConfigTOML(spaced)["build.sub.x"] == .integer(1))
        #expect(try C.updatedConfigTOML(spaced, key: "build.sub.y", value: .integer(2)) == "[ build . sub ]\nx = 1\ny = 2\n")
    }

    @Test func keepsTheLastLineWithoutABreak() throws {
        #expect(try C.updatedConfigTOML("[build]\ncpus = 4", key: "build.memory", value: .string("1g"))
            == "[build]\ncpus = 4\nmemory = \"1g\"")
        #expect(try C.updatedConfigTOML("[build]", key: "build.cpus", value: .integer(1)) == "[build]\ncpus = 1")
        #expect(try C.updatedConfigTOML("# only a comment", key: "dns.domain", value: .string("t"))
            == "# only a comment\n\n[dns]\ndomain = \"t\"\n")
    }

    @Test func refusesArraysOfTables() throws {
        let toml = "[[build]]\ncpus = 1\n[[build]]\ncpus = 2\n"
        #expect(C.parseConfigTOML(toml)["build.cpus"] == nil)
        #expect(throws: ConfigTOMLError.self) { try C.updatedConfigTOML(toml, key: "build.cpus", value: .integer(4)) }
        #expect(throws: ConfigTOMLError.self) { try C.updatedConfigTOML(toml, key: "build.memory", value: .string("1g")) }
    }

    @Test func refusesKeysUnderValues() throws {
        let toml = "[build]\ncpus = 4\n"
        #expect(throws: ConfigTOMLError.self) { try C.updatedConfigTOML(toml, key: "build.cpus.x", value: .integer(1)) }
        // `build` is a table, not a value.
        #expect(throws: ConfigTOMLError.self) { try C.updatedConfigTOML("[a.build]\nx = 1\n", key: "a.build", value: .integer(1)) }
    }

    // MARK: - Invalid files

    @Test func refusesInvalidFiles() {
        let invalid = [
            "[build\ncpus = 4\n",
            "[build]\ncpus = 4\ncpus = 5\n",
            "[build]\n[build]\n",
            "a.b = 1\n[a.b]\n",
            "a = { b = 1 }\na.c = 2\n",
            "x = \"open\n",
            "x = [1, 2\n",
            "x = 1 y = 2\n",
            "x = 01\n",
            "x = what\n",
            "x = \"\\q\"\n",
            "x = 1\r[y]\n",
            "= 1\n",
            "x = \"\"\"never closed\n"
        ]
        for toml in invalid {
            #expect(throws: ConfigTOMLError.self, "\(toml.debugDescription)") {
                try C.updatedConfigTOML(toml, key: "dns.domain", value: .string("x"))
            }
        }
        // The reader gives no values instead of guessing.
        #expect(C.parseConfigTOML("[build]\ncpus = 4\ncpus = 5\n").isEmpty)
    }

    @Test func readsAllValueTypes() throws {
        let toml = """
        a = 0x1F
        b = 0o17
        c = 0b101
        d = -1_000
        e = 6.5e-1
        f = inf
        g = 1979-05-27 07:32:00Z
        h = 1979-05-27
        i = ""\"
          one \\
          two""\"
        j = '''it's'''
        k = "\\u00e9\\t"
        l = [ { x = 1 }, { x = 1 } ]
        m.n.o = true

        """
        let values = C.parseConfigTOML(toml)
        #expect(values["a"] == .integer(31))
        #expect(values["b"] == .integer(15))
        #expect(values["c"] == .integer(5))
        #expect(values["d"] == .integer(-1000))
        #expect(values["e"] == .number(0.65))
        #expect(values["f"] == .number(.infinity))
        #expect(values["g"] == .other("1979-05-27 07:32:00Z"))
        #expect(values["h"] == .other("1979-05-27"))
        #expect(values["i"] == .string("  one two"))
        #expect(values["j"] == .string("it's"))
        #expect(values["k"] == .string("é\t"))
        #expect(values["l"] == .other("[ { x = 1 }, { x = 1 } ]"))
        #expect(values["m.n.o"] == .bool(true))
    }

    /// `container system property ls` (TOML) and `--format json` (CLI 1.6.1)
    /// read to the same values.
    @Test func readsTheCLIPropertyListing() {
        let toml = """

        [build]
        cpus = 2
        image = "ghcr.io/apple/container-builder-shim/builder:0.13.2"
        memory = "2048mb"
        rosetta = true

        [container]
        cpus = 4
        memory = "1gb"

        [dns]

        [machine]
        homeMount = "rw"
        virtualization = false

        """
        let json = #"{"build":{"cpus":2,"image":"ghcr.io/apple/container-builder-shim/builder:0.13.2","memory":"2048mb","rosetta":true},"container":{"cpus":4,"memory":"1gb"},"dns":{},"machine":{"homeMount":"rw","virtualization":false}}"#
        #expect(C.parseConfigTOML(toml) == C.parsePropertyList(json))
    }

    // MARK: - Round trips

    @Test func roundTripsSetAndClear() throws {
        let files = [
            "",
            "# header comment\n\n[build]\ncpus = 2 # two\n\n[dns]\n",
            "[build]\r\ncpus = 2\r\n",
            "build.cpus = 2\n",
            "[kernel]\nurl = \"https://x\"\n[[extra]]\nname = 'a'\n"
        ]
        for file in files {
            let set = try C.updatedConfigTOML(file, key: "network.subnet", value: .string("10.0.0.0/24"))
            #expect(C.parseConfigTOML(set)["network.subnet"] == .string("10.0.0.0/24"))
            let cleared = try C.updatedConfigTOML(set, key: "network.subnet", value: nil)
            // Only the added table header stays behind.
            #expect(C.parseConfigTOML(cleared) == C.parseConfigTOML(file), "\(file.debugDescription)")
            #expect(cleared.hasPrefix(file))
            // Setting the same value again changes nothing.
            #expect(try C.updatedConfigTOML(set, key: "network.subnet", value: .string("10.0.0.0/24")) == set)
        }
        let existing = "[build]\ncpus = 2 # two\nmemory = \"1g\"\n"
        let changed = try C.updatedConfigTOML(existing, key: "build.cpus", value: .integer(3))
        #expect(try C.updatedConfigTOML(changed, key: "build.cpus", value: .integer(2)) == existing)
    }

    @Test func quotesStringValues() throws {
        let tricky = "a\"b\\c\n[x]\td"
        let out = try C.updatedConfigTOML("[build]\n", key: "build.image", value: .string(tricky))
        #expect(C.parseConfigTOML(out) == ["build.image": .string(tricky)])
    }

    @Test func refusesRawLiteralsThatBreakTheLine() {
        #expect(throws: ConfigTOMLError.self) {
            try C.updatedConfigTOML("[build]\n", key: "build.cpus", value: .other("1\n[kernel]\nurl = \"x\""))
        }
        #expect(throws: ConfigTOMLError.self) {
            try C.updatedConfigTOML("[build]\n", key: "build.cpus", value: .other("1 # x"))
        }
        #expect(throws: ConfigTOMLError.self) {
            try C.updatedConfigTOML("[build]\n", key: "build.cpus", value: .other("1, y = 2"))
        }
    }

    // MARK: - Keys

    @Test func validatesPropertyKeys() throws {
        for key in ["build.cpus", "plugin.foo.bar", "a-b.c_d"] {
            #expect(C.isValidPropertyKey(key))
        }
        let bad = [
            "cpus", "", "build.", ".cpus", "build..cpus", "build.cpus\n[kernel]", "build\n[kernel]\nbinaryPath = \"x\"\n[z.y.cpus",
            "build.\"cpus\"", "build.cpus]", "[build].cpus", "build.cpus = 1", "build.c pus", "build.cpüs"
        ]
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("config.toml")
        try "[build]\ncpus = 4\n".write(to: file, atomically: true, encoding: .utf8)
        for key in bad {
            #expect(!C.isValidPropertyKey(key), "\(key.debugDescription)")
            #expect(throws: AppleSystemError.self) { try C.setUserProperty(key, to: "2", configURL: file) }
            #expect(throws: AppleSystemError.self) { try C.clearUserProperty(key, configURL: file) }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "[build]\ncpus = 4\n")
    }

    // MARK: - Writing the file

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-toml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func permissions(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? -1
    }

    @Test func writesThroughSymlinks() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let dotfiles = folder.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let real = dotfiles.appendingPathComponent("config.toml")
        try "[build]\ncpus = 4\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        let configFolder = folder.appendingPathComponent("home/.config/container", isDirectory: true)
        try FileManager.default.createDirectory(at: configFolder, withIntermediateDirectories: true)
        let link = configFolder.appendingPathComponent("config.toml")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../../dotfiles/config.toml")

        try C.setUserProperty("build.cpus", to: "2", configURL: link)
        try C.setDefaultDNSDomain("test", configURL: link)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "../../../dotfiles/config.toml")
        #expect(try String(contentsOf: real, encoding: .utf8) == "[build]\ncpus = 2\n\n[dns]\ndomain = \"test\"\n")
        #expect(try permissions(real) == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dotfiles.path)
        #expect(leftovers == ["config.toml"])

        try C.clearUserProperty("dns.domain", configURL: link)
        try C.setDefaultDNSDomain(nil, configURL: link)
        #expect(try String(contentsOf: real, encoding: .utf8) == "[build]\ncpus = 2\n\n[dns]\n")
    }

    @Test func createsMissingFileAndFolder() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("new/.config/container/config.toml")
        try C.setUserProperty("build.cpus", to: "3", configURL: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "[build]\ncpus = 3\n")
        #expect(try permissions(file) == 0o644)
        #expect(try permissions(file.deletingLastPathComponent()) == 0o755)

        // A dangling link: the file is created at its target.
        let target = folder.appendingPathComponent("target.toml")
        let link = folder.appendingPathComponent("link.toml")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        try C.setUserProperty("dns.domain", to: "test", configURL: link)
        #expect(try String(contentsOf: target, encoding: .utf8) == "[dns]\ndomain = \"test\"\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    }

    @Test func leavesUnreadableAndInvalidFilesAlone() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = folder.appendingPathComponent("binary.toml")
        let bytes = Data([0xFF, 0xFE, 0x00, 0x41])
        try bytes.write(to: binary)
        #expect(throws: (any Error).self) { try C.setUserProperty("build.cpus", to: "2", configURL: binary) }
        #expect(try Data(contentsOf: binary) == bytes)

        let invalid = folder.appendingPathComponent("invalid.toml")
        try "[build\ncpus = 4\n".write(to: invalid, atomically: true, encoding: .utf8)
        #expect(throws: ConfigTOMLError.self) { try C.setDefaultDNSDomain("test", configURL: invalid) }
        #expect(try String(contentsOf: invalid, encoding: .utf8) == "[build\ncpus = 4\n")
    }

    @Test func dnsDomainUsesTheReader() throws {
        #expect(C.parseDNSDomain("dns.domain = \"a\"\n") == "a")
        #expect(C.parseDNSDomain("dns = { domain = 'b' }\n") == "b")
        #expect(C.parseDNSDomain("[dns]\r\ndomain = \"c\" # x\r\n") == "c")
        #expect(C.parseDNSDomain("[dns]\ndomainx = \"d\"\n") == nil)
        #expect(C.parseDNSDomain("[dns]\ndomain = \"\"\n") == nil)
    }

    // MARK: - Pending restart

    @Test func comparesNormalisedValues() {
        func pending(_ kind: AppleSystemPropertyKind, user: AppleSystemPropertyValue, effective: AppleSystemPropertyValue?) -> Bool {
            AppleSystemProperty(key: "x.y", kind: kind, effective: effective, user: user).isPendingRestart
        }
        #expect(!pending(.memory, user: .string("4g"), effective: .string("4gb")))
        #expect(!pending(.memory, user: .string("4096m"), effective: .string("4096mb")))
        #expect(!pending(.memory, user: .string("4096mb"), effective: .string("4gb")))
        #expect(!pending(.memory, user: .string("2048MiB"), effective: .string("2048mb")))
        #expect(pending(.memory, user: .string("2g"), effective: .string("4gb")))
        #expect(!pending(.count, user: .integer(4), effective: .integer(4)))
        #expect(pending(.count, user: .integer(4), effective: .integer(2)))
        #expect(!pending(.unknown, user: .integer(1), effective: .number(1)))
        #expect(!pending(.bool, user: .bool(true), effective: .bool(true)))
        #expect(!pending(.unknown, user: .other("[ \"1.1.1.1\", 'x' ]"), effective: .other("[\"1.1.1.1\",\"x\"]")))
        #expect(pending(.unknown, user: .other("[\"1.1.1.1\"]"), effective: .other("[\"8.8.8.8\"]")))
        #expect(pending(.domain, user: .string("test"), effective: nil))
        #expect(AppleContainerControl.memoryBytes("1g") == 1_073_741_824)
        #expect(AppleContainerControl.memoryBytes("12") == 12)
        #expect(AppleContainerControl.memoryBytes("4x") == nil)
    }
}
