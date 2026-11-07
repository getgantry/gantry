import Foundation

/// Reads a pasted `docker run …` or `container run …` command into a
/// ``ContainerRecipe``. Flags the form cannot hold are returned as
/// ``RunCommandParser/Result/unsupported`` with their raw text, never dropped.
public enum RunCommandParser {
    /// Which CLI the command was written for. Some short flags differ:
    /// `-c` is `--cpus` for apple/container and `--cpu-shares` for Docker.
    public enum Dialect: Sendable, Equatable {
        case docker
        case appleContainer
    }

    /// A flag that the form cannot hold.
    public struct Unsupported: Sendable, Equatable, Identifiable {
        public var id: Int
        /// The flag and its value as written, for example `--cap-add NET_ADMIN`.
        public var raw: String
        /// Why it was not used.
        public var reason: String

        public init(id: Int, raw: String, reason: String) {
            self.id = id
            self.raw = raw
            self.reason = reason
        }
    }

    public struct Result: Sendable, Equatable {
        public var recipe: ContainerRecipe
        public var dialect: Dialect
        public var unsupported: [Unsupported]
        /// Things the user should check, for example an `--env-file`.
        public var notes: [String]
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case empty
        case shell(ShellWords.ParseError)
        case notRunCommand(String)
        case missingImage
        case missingValue(String)

        public var errorDescription: String? {
            switch self {
            case .empty:
                String(localized: "Paste a docker run or container run command.", bundle: .module)
            case .shell(let error):
                error.errorDescription
            case .notRunCommand(let text):
                String(localized: "“\(text)” is not a run command. Paste a docker run or container run command.", bundle: .module)
            case .missingImage:
                String(localized: "The command has no image.", bundle: .module)
            case .missingValue(let flag):
                String(localized: "The option \(flag) has no value.", bundle: .module)
            }
        }
    }

    // MARK: - Entry point

    public static func parse(_ text: String) throws(ParseError) -> Result {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let words: [String]
        do {
            words = try ShellWords.split(normalized)
        } catch let error as ShellWords.ParseError {
            throw .shell(error)
        } catch {
            throw .empty
        }
        var state = State()
        let arguments = try leadingCommand(words, state: &state)
        try parseArguments(arguments, state: &state)
        guard !state.recipe.image.isEmpty else { throw .missingImage }
        return Result(
            recipe: state.recipe,
            dialect: state.dialect,
            unsupported: state.unsupported,
            notes: state.notes
        )
    }

    // MARK: - State

    struct State {
        // Without `-d`, `docker run` stays in the foreground.
        var recipe: ContainerRecipe = {
            var recipe = ContainerRecipe()
            recipe.detach = false
            return recipe
        }()
        var dialect: Dialect = .docker
        var unsupported: [Unsupported] = []
        var notes: [String] = []

        mutating func reject(_ raw: String, _ reason: String) {
            unsupported.append(Unsupported(id: unsupported.count, raw: raw, reason: reason))
        }

        mutating func note(_ text: String) {
            if !notes.contains(text) { notes.append(text) }
        }
    }

    // MARK: - Program and subcommand

    private static let programs: [String: Dialect] = [
        "docker": .docker, "podman": .docker, "nerdctl": .docker, "container": .appleContainer,
    ]
    private static let separators: Set<String> = ["&&", "||", ";", "|", "&"]

    /// Strips the prompt, `sudo`, the program and `run`, and anything after
    /// a shell separator. Returns the run arguments.
    private static func leadingCommand(_ words: [String], state: inout State) throws(ParseError) -> [String] {
        var list = words
        if let cut = list.firstIndex(where: { separators.contains($0) }) {
            list = Array(list[..<cut])
            state.note(String(localized: "The text has more than one command. Only the first command is used.", bundle: .module))
        }
        while let first = list.first, first == "$" || first == "sudo" || first == "%" {
            list.removeFirst()
        }
        guard let first = list.first else { throw .empty }

        let program = (first as NSString).lastPathComponent
        if let dialect = programs[program] {
            state.dialect = dialect
            list.removeFirst()
            skipGlobalOptions(&list, state: &state)
            if dialect == .docker, list.first == "container" { list.removeFirst() }
            guard let sub = list.first else { throw .notRunCommand(first) }
            guard sub == "run" || sub == "create" else { throw .notRunCommand("\(program) \(sub)") }
            list.removeFirst()
        } else if first == "run" || first == "create" {
            list.removeFirst()
        } else if !first.hasPrefix("-"), !looksLikeImage(first) {
            // Options or a bare image are fine; another word is not a run command.
            throw .notRunCommand(first)
        }
        return list
    }

    private static func looksLikeImage(_ word: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-/:@")
        return !word.isEmpty && word.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Docker options before the subcommand, such as `--context prod`.
    private static func skipGlobalOptions(_ list: inout [String], state: inout State) {
        let withValue: Set<String> = ["--context", "-c", "-H", "--host", "--config", "--log-level", "-l"]
        while let first = list.first, first.hasPrefix("-") {
            list.removeFirst()
            var raw = first
            if withValue.contains(first), let value = list.first {
                list.removeFirst()
                raw += " " + value
            }
            state.reject(raw, String(localized: "Global options are not used. Gantry uses the selected host.", bundle: .module))
        }
    }

    // MARK: - Options

    private static func parseArguments(_ arguments: [String], state: inout State) throws(ParseError) {
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            if word == "--" {
                if index < arguments.count {
                    setImage(arguments[index], rest: Array(arguments[(index + 1)...]), state: &state)
                }
                return
            }
            if word.hasPrefix("--") {
                try parseLong(word, arguments, &index, state: &state)
            } else if word.hasPrefix("-"), word.count > 1 {
                try parseShortCluster(word, arguments, &index, state: &state)
            } else {
                setImage(word, rest: Array(arguments[index...]), state: &state)
                return
            }
        }
    }

    private static func setImage(_ image: String, rest: [String], state: inout State) {
        state.recipe.image = image
        state.recipe.command = rest
    }

    private static func takeValue(
        _ flag: String, _ arguments: [String], _ index: inout Int
    ) throws(ParseError) -> String {
        guard index < arguments.count else { throw .missingValue(flag) }
        let value = arguments[index]
        index += 1
        return value
    }

    private static func value(
        _ inline: String?, _ flag: String, _ arguments: [String], _ index: inout Int
    ) throws(ParseError) -> String {
        if let inline { return inline }
        return try takeValue(flag, arguments, &index)
    }

    private static func parseLong(
        _ word: String, _ arguments: [String], _ index: inout Int, state: inout State
    ) throws(ParseError) {
        var name = word
        var inline: String?
        if let eq = word.firstIndex(of: "=") {
            name = String(word[..<eq])
            inline = String(word[word.index(after: eq)...])
        }
        try handle(name, inline: inline, arguments, &index, state: &state)
    }

    /// `-it`, `-p8080:80`, `-dp 80:80`.
    private static func parseShortCluster(
        _ word: String, _ arguments: [String], _ index: inout Int, state: inout State
    ) throws(ParseError) {
        let letters = Array(word.dropFirst())
        var position = 0
        while position < letters.count {
            let flag = "-" + String(letters[position])
            position += 1
            if takesValue(flag, dialect: state.dialect) {
                var rest = String(letters[position...])
                if rest.hasPrefix("=") { rest.removeFirst() }
                try handle(flag, inline: rest.isEmpty ? nil : rest, arguments, &index, state: &state)
                return
            }
            try handle(flag, inline: nil, arguments, &index, state: &state)
        }
    }

    // MARK: - Flag tables

    private static func canonical(_ flag: String, dialect: Dialect) -> String {
        switch (flag, dialect) {
        case ("-c", .appleContainer): "--cpus"
        case ("-a", .appleContainer): "--arch"
        case ("-k", .appleContainer): "--kernel"
        case ("--remove", .appleContainer): "--rm"
        case ("--cwd", _): "--workdir"
        default: aliases[flag] ?? flag
        }
    }

    private static let aliases: [String: String] = [
        "-p": "--publish", "-e": "--env", "-v": "--volume", "-l": "--label", "-m": "--memory",
        "-w": "--workdir", "-u": "--user", "-d": "--detach", "-t": "--tty", "-i": "--interactive",
        "--net": "--network", "-h": "--hostname", "-a": "--attach", "-c": "--cpu-shares",
        "-P": "--publish-all", "-q": "--quiet",
    ]

    /// Flags the form fills from a value.
    private static let valueFlags: Set<String> = [
        "--name", "--publish", "--env", "--env-file", "--volume", "--mount", "--label", "--network",
        "--restart", "--cpus", "--memory", "--entrypoint", "--workdir", "--user", "--dns-domain",
        "--kernel", "--kernel-arg",
    ]
    private static let boolFlags: Set<String> = ["--detach", "--rm", "--tty", "--interactive"]

    /// Docker flags with a value that the form has no field for.
    private static let unsupportedValueFlags: Set<String> = [
        "--add-host", "--annotation", "--arch", "--attach", "--blkio-weight", "--cap-add", "--cap-drop",
        "--cgroup-parent", "--cgroupns", "--cidfile", "--cpu-period", "--cpu-quota", "--cpu-shares",
        "--cpuset-cpus", "--cpuset-mems", "--device", "--device-cgroup-rule", "--dns", "--dns-option",
        "--dns-search", "--domainname", "--expose", "--gid", "--gpus", "--group-add", "--health-cmd",
        "--health-interval", "--health-retries", "--health-start-period", "--health-timeout",
        "--hostname", "--init-image", "--ip", "--ip6", "--ipc", "--isolation", "--label-file", "--link",
        "--log-driver", "--log-opt", "--mac-address", "--memory-reservation", "--memory-swap",
        "--memory-swappiness", "--network-alias", "--os", "--pid", "--pids-limit", "--platform",
        "--publish-socket", "--pull", "--runtime", "--scheme", "--security-opt", "--shm-size",
        "--stop-signal", "--stop-timeout", "--storage-opt", "--sysctl", "--tmpfs", "--uid",
        "--ulimit", "--userns", "--uts", "--virtualization", "--volume-driver", "--volumes-from",
        "--detach-keys", "--cpu-rt-period", "--cpu-rt-runtime", "--kernel-memory", "--oom-score-adj",
        "--platform-arch", "--progress",
    ]

    private static func takesValue(_ flag: String, dialect: Dialect) -> Bool {
        let name = canonical(flag, dialect: dialect)
        return valueFlags.contains(name) || unsupportedValueFlags.contains(name)
    }

    private static func handle(
        _ flag: String, inline: String?, _ arguments: [String], _ index: inout Int, state: inout State
    ) throws(ParseError) {
        let name = canonical(flag, dialect: state.dialect)
        if boolFlags.contains(name) {
            let on = inline.map { !["false", "0"].contains($0.lowercased()) } ?? true
            setBool(name, on, state: &state)
        } else if valueFlags.contains(name) {
            let value = try value(inline, flag, arguments, &index)
            apply(name, value: value, raw: rawText(flag, value, inline: inline != nil), state: &state)
        } else if unsupportedValueFlags.contains(name) {
            let value = try value(inline, flag, arguments, &index)
            state.reject(rawText(flag, value, inline: inline != nil), String(localized: "Not supported by the New Container form.", bundle: .module))
        } else {
            let raw = inline.map { "\(flag)=\($0)" } ?? flag
            state.reject(raw, String(localized: "Not supported by the New Container form.", bundle: .module))
        }
    }

    /// The flag as the user wrote it: `--name=web` or `--name web`.
    private static func rawText(_ flag: String, _ value: String, inline: Bool) -> String {
        inline && flag.hasPrefix("--") ? "\(flag)=\(value)" : "\(flag) \(value)"
    }

    private static func setBool(_ name: String, _ on: Bool, state: inout State) {
        switch name {
        case "--detach": state.recipe.detach = on
        case "--rm": state.recipe.autoRemove = on
        case "--tty": state.recipe.tty = on
        case "--interactive": state.recipe.interactive = on
        default: break
        }
    }

    private static func apply(_ name: String, value: String, raw: String, state: inout State) {
        switch name {
        case "--name": state.recipe.name = value
        case "--publish": RunCommandValues.addPorts(value, raw: raw, state: &state)
        case "--env": RunCommandValues.addEnv(value, state: &state)
        case "--env-file":
            state.recipe.envFiles.append(value)
            state.note(String(localized: "Gantry does not read env files. Add the variables from \(value) by hand.", bundle: .module))
        case "--volume": RunCommandValues.addVolume(value, raw: raw, state: &state)
        case "--mount": RunCommandValues.addMount(value, raw: raw, state: &state)
        case "--label": RunCommandValues.addLabel(value, state: &state)
        case "--network": RunCommandValues.setNetwork(value, raw: raw, state: &state)
        case "--restart": RunCommandValues.setRestart(value, raw: raw, state: &state)
        case "--cpus": RunCommandValues.setCPUs(value, raw: raw, state: &state)
        case "--memory": RunCommandValues.setMemory(value, raw: raw, state: &state)
        case "--entrypoint": state.recipe.entrypoint = value
        case "--workdir": state.recipe.workdir = value
        case "--user": state.recipe.user = value
        case "--dns-domain": state.recipe.dnsDomain = value
        case "--kernel": state.recipe.kernel = value
        case "--kernel-arg": state.recipe.kernelArgs.append(value)
        default: break
        }
    }
}
