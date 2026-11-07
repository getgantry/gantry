import Foundation

/// Prints a ``ContainerRecipe`` as a `docker run` or `container run`
/// command that ``RunCommandParser`` reads back to the same recipe.
public enum RunCommandFormatter {
    /// One option per line, joined with ` \` line continuations.
    public static func command(for recipe: ContainerRecipe, dialect: RunCommandParser.Dialect) -> String {
        let docker = dialect == .docker
        var head = docker ? "docker run" : "container run"
        var bools: [String] = []
        if recipe.detach { bools.append(docker ? "-d" : "--detach") }
        if recipe.autoRemove { bools.append("--rm") }
        if recipe.interactive { bools.append(docker ? "-i" : "--interactive") }
        if recipe.tty { bools.append(docker ? "-t" : "--tty") }
        if !bools.isEmpty { head += " " + bools.joined(separator: " ") }
        let lines = optionLines(recipe, dialect: dialect)
        let tail = ([recipe.image] + recipe.command).map(ShellQuoting.quote).joined(separator: " ")
        return ([head] + lines.map { "  " + $0 } + ["  " + tail]).joined(separator: " \\\n")
    }

    private static func optionLines(_ recipe: ContainerRecipe, dialect: RunCommandParser.Dialect) -> [String] {
        let docker = dialect == .docker
        var lines: [String] = []
        func add(_ flag: String, _ value: String) {
            lines.append("\(flag) \(ShellQuoting.quote(value))")
        }
        if !recipe.name.isEmpty { add("--name", recipe.name) }
        for port in recipe.ports where !port.container.isEmpty {
            add(docker ? "-p" : "--publish", portSpec(port))
        }
        for env in recipe.env where !env.key.isEmpty { add(docker ? "-e" : "--env", "\(env.key)=\(env.value)") }
        for file in recipe.envFiles { add("--env-file", file) }
        for volume in recipe.volumes where !volume.source.isEmpty && !volume.target.isEmpty {
            add(docker ? "-v" : "--volume", volume.bind)
        }
        for label in recipe.labels where !label.key.isEmpty {
            add(docker ? "-l" : "--label", "\(label.key)=\(label.value)")
        }
        addResources(recipe, docker: docker, add: add)
        if !recipe.entrypoint.isEmpty { add("--entrypoint", recipe.entrypoint) }
        if !recipe.workdir.isEmpty { add(docker ? "-w" : "--workdir", recipe.workdir) }
        if !recipe.user.isEmpty { add(docker ? "-u" : "--user", recipe.user) }
        if !docker {
            if !recipe.dnsDomain.isEmpty { add("--dns-domain", recipe.dnsDomain) }
            if !recipe.kernel.isEmpty { add("--kernel", recipe.kernel) }
            for arg in recipe.kernelArgs where !arg.isEmpty { add("--kernel-arg", arg) }
        }
        return lines
    }

    private static func addResources(
        _ recipe: ContainerRecipe, docker: Bool, add: (String, String) -> Void
    ) {
        let net = recipe.network.trimmingCharacters(in: .whitespaces)
        if !ContainerRecipe.isDefaultNetwork(net) { add("--network", net) }
        if docker, !recipe.restartPolicy.isEmpty, recipe.restartPolicy != "no" {
            add("--restart", recipe.restartPolicy)
        }
        if let nano = ContainerRecipe.nanoCPUs(recipe.cpus) {
            // apple/container takes whole CPUs, as the transport sends them.
            add("--cpus", docker ? recipe.cpus.trimmingCharacters(in: .whitespaces)
                : String(max(nano / 1_000_000_000, 1)))
        }
        if let bytes = ContainerRecipe.memoryBytes(recipe.memory) {
            add(docker ? "-m" : "--memory", docker ? recipe.memory.trimmingCharacters(in: .whitespaces)
                : "\(max(bytes / 1_048_576, 1))M")
        }
    }

    static func portSpec(_ port: ContainerRecipe.Port) -> String {
        var spec = port.container
        if !port.host.isEmpty || !port.hostIP.isEmpty { spec = "\(port.host):\(spec)" }
        if !port.hostIP.isEmpty {
            let ip = port.hostIP.contains(":") ? "[\(port.hostIP)]" : port.hostIP
            spec = "\(ip):\(spec)"
        }
        return port.proto == "tcp" ? spec : "\(spec)/\(port.proto)"
    }
}

/// POSIX shell quoting, the reverse of ``ShellWords``.
public enum ShellQuoting {
    private static let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")

    /// `word` as is when it is safe, else in single quotes.
    public static func quote(_ word: String) -> String {
        if !word.isEmpty, word.allSatisfy({ safe.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Words joined so that ``ShellWords/split(_:)`` gives them back.
    public static func join(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }
}
