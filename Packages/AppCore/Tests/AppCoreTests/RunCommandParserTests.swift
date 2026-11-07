import Foundation
import Testing
@testable import AppCore

private func parse(_ text: String) throws -> RunCommandParser.Result {
    try RunCommandParser.parse(text)
}

@Test func runParserReadsTypicalDockerCommand() throws {
    let result = try parse("""
    docker run -d --name web \\
      -p 8080:80 -p 127.0.0.1:8443:443/tcp \\
      -e MODE=prod -e "GREETING=hello world" \\
      -v /srv/data:/data:ro -v cache:/cache \\
      --network backend --restart unless-stopped \\
      -l app=web --cpus 1.5 -m 512m \\
      -w /app -u 1000:1000 --rm -it \\
      nginx:alpine nginx -g 'daemon off;'
    """)
    let r = result.recipe
    #expect(result.dialect == .docker)
    #expect(result.unsupported.isEmpty)
    #expect(r.image == "nginx:alpine")
    #expect(r.command == ["nginx", "-g", "daemon off;"])
    #expect(r.name == "web")
    #expect(r.ports == [
        .init(host: "8080", container: "80"),
        .init(hostIP: "127.0.0.1", host: "8443", container: "443"),
    ])
    #expect(r.env == [.init(key: "MODE", value: "prod"), .init(key: "GREETING", value: "hello world")])
    #expect(r.volumes == [.init(source: "/srv/data", target: "/data", readOnly: true), .init(source: "cache", target: "/cache")])
    #expect(r.network == "backend")
    #expect(r.restartPolicy == "unless-stopped")
    #expect(r.labels == [.init(key: "app", value: "web")])
    #expect(r.cpus == "1.5")
    #expect(r.memory == "512m")
    #expect(r.workdir == "/app")
    #expect(r.user == "1000:1000")
    #expect(r.detach && r.autoRemove && r.interactive && r.tty)
}

@Test func runParserReadsAppleContainerCommand() throws {
    let result = try parse("container run --detach --name db -c 2 -m 1G --publish 5432:5432 --dns-domain test --kernel /k/vmlinux --remove postgres:16")
    let r = result.recipe
    #expect(result.dialect == .appleContainer)
    #expect(result.unsupported.isEmpty)
    #expect(r.cpus == "2")
    #expect(r.memory == "1G")
    #expect(r.dnsDomain == "test")
    #expect(r.kernel == "/k/vmlinux")
    #expect(r.autoRemove)
    #expect(r.image == "postgres:16")
}

@Test func runParserShortFlagMeaningDependsOnDialect() throws {
    let docker = try parse("docker run -c 512 alpine")
    #expect(docker.recipe.cpus.isEmpty)
    #expect(docker.unsupported.map(\.raw) == ["-c 512"])
    let apple = try parse("container run -c 2 alpine")
    #expect(apple.recipe.cpus == "2")
}

@Test func runParserAcceptsPrefixesAndSubcommands() throws {
    #expect(try parse("$ sudo docker container run alpine").recipe.image == "alpine")
    #expect(try parse("/usr/local/bin/docker create alpine").recipe.image == "alpine")
    #expect(try parse("podman run alpine").recipe.image == "alpine")
    #expect(try parse("run -d alpine").recipe.detach)
    #expect(try parse("-p 80:80 nginx").recipe.ports.count == 1)
    #expect(try parse("nginx:alpine").recipe.image == "nginx:alpine")
}

@Test func runParserSkipsGlobalOptionsAndReportsThem() throws {
    let result = try parse("docker --context prod run alpine")
    #expect(result.recipe.image == "alpine")
    #expect(result.unsupported.map(\.raw) == ["--context prod"])
}

@Test func runParserRejectsOtherCommands() {
    #expect(throws: RunCommandParser.ParseError.notRunCommand("docker ps")) { try parse("docker ps -a") }
    #expect(throws: RunCommandParser.ParseError.notRunCommand("ECHO")) { try parse("ECHO hi") }
    #expect(throws: RunCommandParser.ParseError.empty) { try parse("   ") }
    #expect(throws: RunCommandParser.ParseError.missingImage) { try parse("docker run -d") }
    #expect(throws: RunCommandParser.ParseError.missingValue("--name")) { try parse("docker run --name") }
    #expect(throws: RunCommandParser.ParseError.shell(.unterminatedSingleQuote)) { try parse("docker run 'alpine") }
}

@Test func runParserHandlesEqualsAndClusters() throws {
    let r = try parse("docker run --name=web -p8080:80 -dit -e=A=1 --rm=false --env B alpine").recipe
    #expect(r.name == "web")
    #expect(r.ports == [.init(host: "8080", container: "80")])
    #expect(r.detach && r.interactive && r.tty)
    #expect(!r.autoRemove)
    #expect(r.env == [.init(key: "A", value: "1"), .init(key: "B", value: "")])
}

@Test func runParserClusterEndsWithValueFlag() throws {
    let r = try parse("docker run -dp 3000:3000 node").recipe
    #expect(r.detach)
    #expect(r.ports == [.init(host: "3000", container: "3000")])
}

@Test func runParserNotesEnvFromShellAndEnvFile() throws {
    let result = try parse("docker run -e TOKEN --env-file ./.env alpine")
    #expect(result.recipe.env == [.init(key: "TOKEN", value: "")])
    #expect(result.recipe.envFiles == ["./.env"])
    #expect(result.notes.count == 2)
}

@Test func runParserListsUnsupportedFlagsWithRawText() throws {
    let result = try parse("docker run --cap-add NET_ADMIN --privileged --hostname=box --shm-size 1g -P --made-up alpine sh")
    #expect(result.unsupported.map(\.raw) == ["--cap-add NET_ADMIN", "--privileged", "--hostname=box", "--shm-size 1g", "-P", "--made-up"])
    #expect(result.recipe.image == "alpine")
    #expect(result.recipe.command == ["sh"])
}

@Test func runParserCommandAfterImageKeepsItsFlags() throws {
    let r = try parse("docker run alpine ls -la --color=auto").recipe
    #expect(r.command == ["ls", "-la", "--color=auto"])
}

@Test func runParserDoubleDashEndsOptions() throws {
    let r = try parse("docker run -d -- alpine -x").recipe
    #expect(r.image == "alpine")
    #expect(r.command == ["-x"])
}

@Test func runParserChecksOnlyTheFirstCommand() {
    #expect(throws: RunCommandParser.ParseError.notRunCommand("docker pull")) {
        try parse("docker pull alpine && docker run alpine")
    }
}

@Test func runParserUsesFirstCommandOnly() throws {
    let result = try parse("docker run -d alpine && docker logs -f x")
    #expect(result.recipe.image == "alpine")
    #expect(result.recipe.command.isEmpty)
    #expect(result.notes.count == 1)
}

@Test func runParserCRLFContinuations() throws {
    let r = try parse("docker run \\\r\n  -p 80:80 \\\r\n  nginx").recipe
    #expect(r.image == "nginx")
    #expect(r.ports.count == 1)
}

// MARK: - Ports

@Test func runParserPortForms() {
    #expect(RunCommandValues.ports("80") == [.init(host: "", container: "80")])
    #expect(RunCommandValues.ports("53:53/udp") == [.init(host: "53", container: "53", proto: "udp")])
    #expect(RunCommandValues.ports("127.0.0.1::80") == [.init(hostIP: "127.0.0.1", host: "", container: "80")])
    #expect(RunCommandValues.ports("[::1]:8080:80") == [.init(hostIP: "::1", host: "8080", container: "80")])
    #expect(RunCommandValues.ports("8000-8002:9000-9002")?.map(\.host) == ["8000", "8001", "8002"])
    #expect(RunCommandValues.ports("8000-8002:9000-9002")?.map(\.container) == ["9000", "9001", "9002"])
    #expect(RunCommandValues.ports("8000-8001:80") == nil)
    #expect(RunCommandValues.ports("80/sctp") == nil)
    #expect(RunCommandValues.ports("99999:80") == nil)
    #expect(RunCommandValues.ports("1-1000") == nil)
    #expect(RunCommandValues.ports("a:b") == nil)
}

@Test func runParserInvalidPortIsUnsupported() throws {
    let result = try parse("docker run -p nope alpine")
    #expect(result.unsupported.map(\.raw) == ["-p nope"])
    #expect(result.recipe.ports.isEmpty)
}

// MARK: - Volumes and mounts

@Test func runParserVolumeOptionsAndAnonymous() throws {
    let result = try parse("docker run -v /a:/b:ro,z -v /anon -v x:/y:rw alpine")
    #expect(result.recipe.volumes == [.init(source: "/a", target: "/b", readOnly: true), .init(source: "x", target: "/y")])
    #expect(result.unsupported.map(\.raw) == ["-v /anon"])
    #expect(result.notes.count == 1)
}

@Test func runParserMounts() throws {
    let result = try parse("""
    docker run --mount type=bind,source=/src,target=/app,readonly \
      --mount src=data,dst=/data \
      --mount type=tmpfs,target=/tmp \
      --mount type=volume,target=/anon \
      --mount type=bind,src=/a,dst=/b,bind-propagation=rshared,ro=false alpine
    """)
    #expect(result.recipe.volumes == [
        .init(source: "/src", target: "/app", readOnly: true),
        .init(source: "data", target: "/data"),
        .init(source: "/a", target: "/b"),
    ])
    #expect(result.unsupported.count == 2)
    #expect(result.notes.count == 1)
}

// MARK: - Other values

@Test func runParserRestartPolicy() throws {
    let r1 = try parse("docker run --restart on-failure:3 alpine")
    #expect(r1.recipe.restartPolicy == "on-failure")
    #expect(r1.notes.count == 1)
    let r2 = try parse("docker run --restart sometimes alpine")
    #expect(r2.recipe.restartPolicy == "no")
    #expect(r2.unsupported.map(\.raw) == ["--restart sometimes"])
}

@Test func runParserSecondNetworkIsUnsupported() throws {
    let result = try parse("docker run --net a --network b alpine")
    #expect(result.recipe.network == "a")
    #expect(result.unsupported.map(\.raw) == ["--network b"])
}

@Test func runParserAppleNetworkAliasKeepsName() throws {
    let result = try parse("container run --network web,alias=api.test alpine")
    #expect(result.recipe.network == "web")
    #expect(result.notes.count == 1)
}

@Test func runParserInvalidLimitsAreUnsupported() throws {
    let result = try parse("docker run --cpus lots -m huge alpine")
    #expect(result.recipe.cpus.isEmpty)
    #expect(result.recipe.memory.isEmpty)
    #expect(result.unsupported.map(\.raw) == ["--cpus lots", "-m huge"])
}

@Test func runParserEntrypointAndLabels() throws {
    let r = try parse("docker run --entrypoint /bin/sh -l flag --label k=v=w alpine -c 'echo hi'").recipe
    #expect(r.entrypoint == "/bin/sh")
    #expect(r.labels == [.init(key: "flag", value: ""), .init(key: "k", value: "v=w")])
    #expect(r.command == ["-c", "echo hi"])
}

@Test func runParserWithoutDetachIsForeground() throws {
    #expect(try !parse("docker run alpine").recipe.detach)
}
