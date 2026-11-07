import Foundation
import Testing
import DockerKit
@testable import AppCore

private func sampleRecipe() -> ContainerRecipe {
    var r = ContainerRecipe(image: "nginx:alpine")
    r.name = "web"
    r.command = ["nginx", "-g", "daemon off;"]
    r.entrypoint = "/docker-entrypoint.sh"
    r.ports = [.init(host: "8080", container: "80"), .init(hostIP: "::1", host: "53", container: "53", proto: "udp")]
    r.env = [.init(key: "A", value: "it's here"), .init(key: "EMPTY", value: "")]
    r.envFiles = ["/etc/app.env"]
    r.volumes = [.init(source: "/srv/my data", target: "/data", readOnly: true)]
    r.labels = [.init(key: "app", value: "web")]
    r.network = "backend"
    r.restartPolicy = "always"
    r.cpus = "1.5"
    r.memory = "512m"
    r.workdir = "/app"
    r.user = "nginx"
    r.tty = true
    r.interactive = true
    r.autoRemove = true
    r.detach = true
    return r
}

// MARK: - Formatter

@Test func recipeDockerCommandRoundTrips() throws {
    let recipe = sampleRecipe()
    let text = RunCommandFormatter.command(for: recipe, dialect: .docker)
    #expect(text.hasPrefix("docker run -d --rm -i -t \\\n  --name web"))
    let back = try RunCommandParser.parse(text)
    #expect(back.unsupported.isEmpty)
    #expect(back.recipe == recipe)
}

@Test func recipeAppleCommandUsesAppleForms() throws {
    var recipe = sampleRecipe()
    recipe.dnsDomain = "test"
    recipe.kernel = "/k"
    recipe.kernelArgs = ["console=hvc0"]
    let text = RunCommandFormatter.command(for: recipe, dialect: .appleContainer)
    #expect(text.hasPrefix("container run --detach --rm --interactive --tty"))
    #expect(!text.contains("--restart"))
    #expect(text.contains("--cpus 1 "))
    #expect(text.contains("--memory 512M "))
    #expect(text.contains("--dns-domain test"))
    let back = try RunCommandParser.parse(text).recipe
    #expect(back.dnsDomain == "test")
    #expect(back.kernel == "/k")
    #expect(back.kernelArgs == ["console=hvc0"])
    #expect(back.ports == recipe.ports)
    #expect(back.env == recipe.env)
    #expect(back.volumes == recipe.volumes)
}

@Test func recipeDockerCommandLeavesAppleOnlyFields() {
    var recipe = ContainerRecipe(image: "alpine")
    recipe.detach = false
    recipe.dnsDomain = "test"
    #expect(RunCommandFormatter.command(for: recipe, dialect: .docker) == "docker run \\\n  alpine")
}

@Test func shellQuotingRoundTrips() throws {
    let words = ["plain", "", "with space", "it's", "$HOME", "a\"b", "tab\there", "x=y:z"]
    #expect(try ShellWords.split(ShellQuoting.join(words)) == words)
    #expect(ShellQuoting.quote("x=y:z") == "x=y:z")
    #expect(ShellQuoting.quote("it's") == "'it'\\''s'")
}

// MARK: - Limits

@Test func recipeMemoryParsing() {
    #expect(ContainerRecipe.memoryBytes("512m") == Int64(512 * 1_048_576))
    #expect(ContainerRecipe.memoryBytes("2G") == Int64(2 * 1_073_741_824))
    #expect(ContainerRecipe.memoryBytes("1.5g") == 1_610_612_736)
    #expect(ContainerRecipe.memoryBytes("256MB") == Int64(256 * 1_048_576))
    #expect(ContainerRecipe.memoryBytes("1024") == 1024)
    #expect(ContainerRecipe.memoryBytes("100b") == 100)
    #expect(ContainerRecipe.memoryBytes("") == nil)
    #expect(ContainerRecipe.memoryBytes("0") == nil)
    #expect(ContainerRecipe.memoryBytes("-1m") == nil)
    #expect(ContainerRecipe.memoryBytes("5x") == nil)
    #expect(ContainerRecipe.memoryText(bytes: 512 * 1_048_576) == "512m")
    #expect(ContainerRecipe.memoryText(bytes: 2 * 1_073_741_824) == "2g")
    #expect(ContainerRecipe.memoryText(bytes: 1000) == "1000")
}

@Test func recipeCPUParsing() {
    #expect(ContainerRecipe.nanoCPUs("1.5") == 1_500_000_000)
    #expect(ContainerRecipe.nanoCPUs("2") == 2_000_000_000)
    #expect(ContainerRecipe.nanoCPUs("0") == nil)
    #expect(ContainerRecipe.nanoCPUs("x") == nil)
    #expect(ContainerRecipe.cpusText(nanoCPUs: 1_500_000_000) == "1.5")
    #expect(ContainerRecipe.cpusText(nanoCPUs: 4_000_000_000) == "4")
    #expect(ContainerRecipe.cpusText(nanoCPUs: 250_000_000) == "0.25")
}

@Test func recipeFieldIssues() {
    var recipe = ContainerRecipe(image: "a")
    #expect(recipe.memoryIssue == nil && recipe.cpusIssue == nil)
    recipe.memory = "lots"
    recipe.cpus = "-1"
    #expect(recipe.memoryIssue != nil)
    #expect(recipe.cpusIssue != nil)
}

// MARK: - Create request

private func encoded(_ request: ContainerCreateRequest) throws -> [String: Any] {
    let data = try JSONEncoder().encode(request)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func recipeRequestOnDockerHost() throws {
    var recipe = sampleRecipe()
    recipe.dnsDomain = "test"
    recipe.kernel = "/k"
    let request = recipe.createRequest(name: "web", isAppleHost: false)
    #expect(request.name == "web")
    #expect(request.entrypoint == ["/docker-entrypoint.sh"])
    #expect(request.cmd == ["nginx", "-g", "daemon off;"])
    #expect(request.env == ["A=it's here", "EMPTY="])
    #expect(request.user == "nginx")
    #expect(request.openStdin == true)
    #expect(request.workingDir == "/app")
    #expect(request.domainname == nil)
    #expect(request.appleOptions == nil)
    #expect(request.labels == ["app": "web"])
    let host = try #require(request.hostConfig)
    #expect(host.memory == Int64(512 * 1_048_576))
    #expect(host.nanoCPUs == 1_500_000_000)
    #expect(host.networkMode == "backend")
    #expect(host.restartPolicy?.name == "always")
    #expect(host.autoRemove == true)
    #expect(host.binds == ["/srv/my data:/data:ro"])
    #expect(host.portBindings?["80/tcp"] == [.init(hostPort: "8080")])
    #expect(host.portBindings?["53/udp"] == [.init(hostIP: "::1", hostPort: "53")])
    #expect(request.exposedPorts?.keys.sorted() == ["53/udp", "80/tcp"])
    #expect(request.networkingConfig?.endpointsConfig.keys.sorted() == ["backend"])
    let json = try encoded(request)
    #expect(json["User"] as? String == "nginx")
    #expect(json["OpenStdin"] as? Bool == true)
}

@Test func recipeRequestOnAppleHost() throws {
    var recipe = sampleRecipe()
    recipe.dnsDomain = "test"
    recipe.kernel = "/k"
    recipe.kernelArgs = ["a=b"]
    let request = recipe.createRequest(name: "web", isAppleHost: true, kernelArgsSupported: false)
    #expect(request.hostConfig?.restartPolicy == nil)
    #expect(request.hostConfig?.networkMode == nil)
    #expect(request.networkingConfig?.endpointsConfig.keys.sorted() == ["backend"])
    #expect(request.domainname == "test")
    #expect(request.labels[ContainerRecipe.dnsDomainLabelKey] == "test")
    #expect(request.appleOptions?.kernel == "/k")
    #expect(request.appleOptions?.kernelArgs == [])
}

@Test func recipeRequestDefaultsAndDockerModes() {
    var recipe = ContainerRecipe(image: " alpine ")
    let plain = recipe.createRequest(name: nil, isAppleHost: false)
    #expect(plain.image == "alpine")
    #expect(plain.cmd == nil && plain.entrypoint == nil && plain.user == nil && plain.openStdin == nil)
    #expect(plain.hostConfig?.restartPolicy == nil)
    #expect(plain.hostConfig?.networkMode == nil)
    #expect(plain.networkingConfig == nil)
    #expect(plain.exposedPorts == nil)
    recipe.network = "host"
    let host = recipe.createRequest(name: nil, isAppleHost: false)
    #expect(host.hostConfig?.networkMode == "host")
    #expect(host.networkingConfig == nil)
    recipe.network = "bridge"
    #expect(recipe.createRequest(name: nil, isAppleHost: false).hostConfig?.networkMode == nil)
}

@Test func recipeHostWarnings() {
    var recipe = ContainerRecipe(image: "a")
    #expect(recipe.hostWarnings(isAppleHost: true).isEmpty)
    #expect(recipe.hostWarnings(isAppleHost: false).isEmpty)
    recipe.restartPolicy = "always"
    recipe.cpus = "1.5"
    recipe.network = "host"
    recipe.ports = [.init(host: "", container: "80")]
    #expect(recipe.hostWarnings(isAppleHost: true).count == 4)
    #expect(recipe.hostWarnings(isAppleHost: false).isEmpty)
    recipe.dnsDomain = "test"
    recipe.kernelArgs = ["x"]
    #expect(recipe.hostWarnings(isAppleHost: false).count == 2)
}

// MARK: - Codable

@Test func recipeDecodesWithMissingKeys() throws {
    let data = Data(#"{"image":"redis","ports":[{"hostIP":"","host":"6379","container":"6379","proto":"tcp"}]}"#.utf8)
    let recipe = try JSONDecoder().decode(ContainerRecipe.self, from: data)
    #expect(recipe.image == "redis")
    #expect(recipe.ports.count == 1)
    #expect(recipe.restartPolicy == "no")
    #expect(recipe.detach)
}

@Test func recipeEncodeDecodeRoundTrip() throws {
    let recipe = sampleRecipe()
    let back = try JSONDecoder().decode(ContainerRecipe.self, from: JSONEncoder().encode(recipe))
    #expect(back == recipe)
}

// MARK: - From inspect

private func details(_ json: String) throws -> ContainerDetails {
    try JSONDecoder().decode(ContainerDetails.self, from: Data(json.utf8))
}

@Test func recipeFromDockerInspect() throws {
    let d = try details("""
    {"Id":"abc","Name":"/web","Image":"sha256:1","State":{"Status":"exited","Running":false,"Paused":false,
     "Restarting":false,"OOMKilled":false,"Pid":0,"ExitCode":0,"Error":"","StartedAt":"","FinishedAt":""},
     "HostConfig":{"Binds":["/srv:/data:ro"],"NetworkMode":"backend","RestartPolicy":{"Name":"always"},
       "Memory":536870912,"NanoCpus":1500000000,"AutoRemove":false,
       "PortBindings":{"80/tcp":[{"HostIp":"","HostPort":"8080"}],"443/tcp":[{"HostIp":"127.0.0.1","HostPort":"8443"}]}},
     "Config":{"Image":"nginx:alpine","Env":["PATH=/usr/bin","MODE=prod"],"Cmd":["nginx","-g","daemon off;"],
       "Entrypoint":["/docker-entrypoint.sh"],"Labels":{"maintainer":"x","app":"web","com.gantry.dns-domain":"test"},
       "Tty":true,"OpenStdin":true,"WorkingDir":"","User":"nginx"},
     "NetworkSettings":{"Ports":{}},
     "Mounts":[{"Type":"bind","Source":"/srv","Destination":"/data","RW":false},
               {"Type":"volume","Name":"cache","Source":"/var/lib/docker/volumes/cache/_data","Destination":"/cache","RW":true}]}
    """)
    var defaults = ContainerRecipe.ImageDefaults()
    defaults.env = ["PATH=/usr/bin"]
    defaults.cmd = ["nginx", "-g", "daemon off;"]
    defaults.entrypoint = ["/docker-entrypoint.sh"]
    defaults.labels = ["maintainer": "x"]
    let r = ContainerRecipe(details: d, image: defaults)
    #expect(r.image == "nginx:alpine")
    #expect(r.name == "web")
    #expect(r.entrypoint.isEmpty && r.command.isEmpty)
    #expect(r.env == [.init(key: "MODE", value: "prod")])
    #expect(r.labels == [.init(key: "app", value: "web")])
    #expect(r.dnsDomain == "test")
    #expect(r.ports == [.init(host: "8080", container: "80"), .init(hostIP: "127.0.0.1", host: "8443", container: "443")])
    #expect(r.volumes == [.init(source: "/srv", target: "/data", readOnly: true), .init(source: "cache", target: "/cache")])
    #expect(r.network == "backend")
    #expect(r.restartPolicy == "always")
    #expect(r.memory == "512m")
    #expect(r.cpus == "1.5")
    #expect(r.user == "nginx")
    #expect(r.tty && r.interactive && r.detach)
}

@Test func recipeFromInspectWithoutImageDefaultsKeepsEverything() throws {
    let d = try details("""
    {"Id":"abc","Name":"/x","State":{"Status":"running","Running":true,"Paused":false,"Restarting":false,
     "OOMKilled":false,"Pid":1,"ExitCode":0,"Error":"","StartedAt":"","FinishedAt":""},
     "HostConfig":{"NetworkMode":"default"},
     "Config":{"Image":"alpine","Cmd":["sleep","1"],"Entrypoint":["/bin/sh","-c"],"Tty":false},
     "NetworkSettings":{"Ports":{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"80"},{"HostIp":"::","HostPort":"80"}]}},
     "Mounts":[{"Type":"virtiofs","Source":"/Users/me/app","Destination":"/app"},{"Type":"tmpfs","Source":"","Destination":"/tmp"}]}
    """)
    let r = ContainerRecipe(details: d)
    #expect(r.entrypoint == "/bin/sh")
    #expect(r.command == ["-c", "sleep", "1"])
    #expect(r.network.isEmpty)
    #expect(r.ports == [.init(host: "80", container: "80")])
    #expect(r.volumes == [.init(source: "/Users/me/app", target: "/app")])
    #expect(r.restartPolicy == "no")
}

@Test func imageDefaultsReadInspectJSON() {
    let data = Data(#"{"Config":{"Env":["A=1"],"Cmd":["sh"],"Entrypoint":null,"WorkingDir":"/w","User":"u","Labels":{"k":"v"}}}"#.utf8)
    let defaults = ContainerRecipe.ImageDefaults(inspectJSON: data)
    #expect(defaults?.env == ["A=1"])
    #expect(defaults?.cmd == ["sh"])
    #expect(defaults?.entrypoint == [])
    #expect(defaults?.workingDir == "/w")
    #expect(defaults?.labels == ["k": "v"])
    #expect(ContainerRecipe.ImageDefaults(inspectJSON: Data("[]".utf8)) == nil)
}

// MARK: - Store

@MainActor
@Test func recipeStoreSavesListsReplacesAndDeletes() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("recipes.json")
    let store = RecipeStore(fileURL: url)
    #expect(store.recipes.isEmpty)
    #expect(store.save(name: "  ", recipe: ContainerRecipe(image: "a")) == nil)
    store.save(name: "Web", recipe: ContainerRecipe(image: "nginx"))
    store.save(name: "api", recipe: ContainerRecipe(image: "node"))
    let replaced = try #require(store.save(name: "web", recipe: ContainerRecipe(image: "caddy")))
    #expect(store.recipes.map(\.name) == ["api", "web"])
    #expect(store.contains(name: "WEB"))

    let reloaded = RecipeStore(fileURL: url)
    #expect(reloaded.recipes.map(\.recipe.image) == ["node", "caddy"])
    #expect(reloaded.recipes.last?.id == replaced.id)

    reloaded.delete(id: replaced.id)
    #expect(RecipeStore(fileURL: url).recipes.map(\.name) == ["api"])
}

@MainActor
@Test func recipeStoreReportsUnreadableFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("recipes.json")
    try Data("not json".utf8).write(to: url)
    let store = RecipeStore(fileURL: url)
    #expect(store.recipes.isEmpty)
    #expect(store.lastError != nil)
    #expect(try Data(contentsOf: url) == Data("not json".utf8))
}
