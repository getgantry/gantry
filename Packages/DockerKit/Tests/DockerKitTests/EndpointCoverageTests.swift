import Foundation
import Testing
@testable import DockerKit

// MARK: - Configurable mock transport

/// A `DockerTransport` that records every request and returns a canned response
/// chosen by a per-test closure keyed on the request. Lets us exercise endpoint
/// request encoding and response decoding without a daemon.
private actor MockTransport: DockerTransport {
    private(set) var requests: [DockerRequest] = []
    private let responder: @Sendable (DockerRequest) -> DockerResponse
    private let streamFactory: @Sendable (DockerRequest) -> DockerByteStream

    init(
        responder: @escaping @Sendable (DockerRequest) -> DockerResponse = { _ in
            DockerResponse(status: 200, headers: [:], body: Data("{}".utf8))
        },
        streamFactory: @escaping @Sendable (DockerRequest) -> DockerByteStream = { _ in
            DockerByteStream(status: 200, headers: [:], bytes: AsyncThrowingStream { $0.finish() })
        }
    ) {
        self.responder = responder
        self.streamFactory = streamFactory
    }

    func execute(_ request: DockerRequest) async throws -> DockerResponse {
        requests.append(request)
        return responder(request)
    }

    func stream(_ request: DockerRequest) async throws -> DockerByteStream {
        requests.append(request)
        return streamFactory(request)
    }

    func hijack(_ request: DockerRequest) async throws -> DockerHijackedConnection {
        requests.append(request)
        return DockerHijackedConnection(
            status: 101,
            headers: [:],
            bytes: AsyncThrowingStream { $0.finish() },
            write: { _ in },
            close: {}
        )
    }

    func shutdown() async {}

    var last: DockerRequest? { requests.last }
    func request(at index: Int) -> DockerRequest { requests[index] }
}

private func jsonResponse(_ json: String, status: Int = 200) -> DockerResponse {
    DockerResponse(status: status, headers: [:], body: Data(json.utf8))
}

private func makeByteStream(_ chunks: [String], status: Int = 200) -> DockerByteStream {
    DockerByteStream(status: status, headers: [:], bytes: AsyncThrowingStream { continuation in
        for chunk in chunks {
            continuation.yield(Data(chunk.utf8))
        }
        continuation.finish()
    })
}

// MARK: - Containers endpoints

@Test func listContainersAddsAllQueryAndDecodes() async throws {
    let json = """
    [{"Id":"abc123def456","Names":["/web"],"Image":"nginx","ImageID":"sha256:img",
      "Command":"nginx","Created":1609459200,
      "Ports":[{"IP":"0.0.0.0","PrivatePort":80,"PublicPort":8080,"Type":"tcp"}],
      "Labels":{"com.docker.compose.project":"proj","com.docker.compose.service":"svc"},
      "State":"running","Status":"Up 2 hours",
      "Mounts":[{"Type":"volume","Name":"v","Source":"/s","Destination":"/d","Mode":"rw","RW":true}]}]
    """
    let transport = MockTransport(responder: { _ in jsonResponse(json) })
    let client = DockerClient(transport: transport)

    let containers = try await client.listContainers(all: false)
    #expect(containers.count == 1)
    let c = containers[0]
    #expect(c.displayName == "web")
    #expect(c.shortID == "abc123def456")
    #expect(c.composeProject == "proj")
    #expect(c.composeService == "svc")
    #expect(c.state == .running)
    #expect(c.state.isRunning)
    #expect(c.createdDate == Date(timeIntervalSince1970: 1_609_459_200))
    #expect(c.ports.first?.display == "0.0.0.0:8080 → 80/tcp")

    let request = await transport.last
    #expect(request?.path == "/v1.47/containers/json")
    #expect(request?.query.contains(URLQueryItem(name: "all", value: "false")) == true)
}

@Test func containerSummaryDisplayNameFallsBackToShortID() throws {
    let json = #"{"Id":"abcdef0123456789","Names":[],"State":"exited","Status":""}"#
    let summary = try JSONDecoder().decode(ContainerSummary.self, from: Data(json.utf8))
    #expect(summary.displayName == "abcdef012345")
    #expect(summary.state == .exited)
}

@Test func portBindingDisplayWithoutPublicPort() {
    let binding = PortBinding(ip: nil, privatePort: 5432, publicPort: nil, type: "tcp")
    #expect(binding.display == "5432/tcp")
}

@Test func containerStateUnknownFallback() throws {
    let state = try JSONDecoder().decode(ContainerState.self, from: Data(#""weird""#.utf8))
    #expect(state == .unknown)
    #expect(!state.isRunning)
}

@Test func inspectContainerDecodesDetails() async throws {
    let json = """
    {"Id":"id1","Created":"2021-01-01T00:00:00Z","Path":"/bin/sh","Args":["-c","x"],
     "State":{"Status":"running","Running":true,"Paused":false,"Restarting":false,
       "OOMKilled":false,"Pid":42,"ExitCode":0,"Error":"","StartedAt":"t1","FinishedAt":"t2",
       "Health":{"Status":"healthy","FailingStreak":0}},
     "Image":"sha256:img","Name":"/web","RestartCount":3,"Platform":"linux",
     "HostConfig":{"Binds":["/h:/c"],"NetworkMode":"bridge",
       "RestartPolicy":{"Name":"always","MaximumRetryCount":0},
       "Memory":1000,"NanoCpus":500,"Privileged":false,"AutoRemove":true},
     "Config":{"Hostname":"h","Env":["A=B"],"Cmd":["sh"],"Entrypoint":["e"],
       "Image":"nginx","Labels":{"k":"v"},"Tty":true,"WorkingDir":"/srv","User":"root"},
     "NetworkSettings":{"IPAddress":"172.0.0.2",
       "Ports":{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"}]},
       "Networks":{"bridge":{"IPAddress":"172.0.0.2","Gateway":"172.0.0.1","MacAddress":"aa:bb"}}},
     "Mounts":[{"Type":"bind","Source":"/s","Destination":"/d"}]}
    """
    let transport = MockTransport(responder: { _ in jsonResponse(json) })
    let client = DockerClient(transport: transport)

    let details = try await client.inspectContainer(id: "id1")
    #expect(details.id == "id1")
    #expect(details.displayName == "web")
    #expect(details.restartCount == 3)
    #expect(details.platform == "linux")
    #expect(details.state.status == .running)
    #expect(details.state.running)
    #expect(details.state.pid == 42)
    #expect(details.state.health?.status == "healthy")
    #expect(details.hostConfig.binds == ["/h:/c"])
    #expect(details.hostConfig.networkMode == "bridge")
    #expect(details.hostConfig.restartPolicy?.name == "always")
    #expect(details.hostConfig.memory == 1000)
    #expect(details.hostConfig.autoRemove == true)
    #expect(details.config.tty)
    #expect(details.config.env == ["A=B"])
    #expect(details.config.workingDir == "/srv")
    #expect(details.networkSettings.ipAddress == "172.0.0.2")
    #expect(details.networkSettings.networks?["bridge"]?.gateway == "172.0.0.1")
    #expect(details.networkSettings.ports?["80/tcp"]??.first?.hostPort == "8080")
    #expect(details.mounts.first?.source == "/s")

    let request = await transport.last
    #expect(request?.path == "/v1.47/containers/id1/json")
}

@Test func containerDetailsDefaultsForMissingOptionalSections() throws {
    // Only required keys present; HostConfig/NetworkSettings default-construct.
    let json = #"{"Id":"id","Name":"/svc","State":{},"Config":{}}"#
    let details = try JSONDecoder().decode(ContainerDetails.self, from: Data(json.utf8))
    #expect(details.displayName == "svc")
    #expect(details.state.status == .unknown)
    #expect(details.hostConfig.binds == nil)
    #expect(details.networkSettings.ipAddress == nil)
    #expect(!details.config.tty)
}

@Test func rawInspectContainerReturnsRawBody() async throws {
    let body = #"{"Id":"raw","custom":123}"#
    let transport = MockTransport(responder: { _ in jsonResponse(body) })
    let client = DockerClient(transport: transport)

    let data = try await client.rawInspectContainer(id: "raw")
    #expect(String(decoding: data, as: UTF8.self) == body)
    let request = await transport.last
    #expect(request?.path == "/v1.47/containers/raw/json")
}

@Test func containerLifecycleEndpointsIssueCorrectRequests() async throws {
    let transport = MockTransport(responder: { _ in
        DockerResponse(status: 204, headers: [:], body: Data())
    })
    let client = DockerClient(transport: transport)

    try await client.startContainer(id: "c")
    try await client.stopContainer(id: "c", timeout: 5)
    try await client.restartContainer(id: "c")
    try await client.killContainer(id: "c", signal: "SIGKILL")
    try await client.pauseContainer(id: "c")
    try await client.unpauseContainer(id: "c")
    try await client.renameContainer(id: "c", to: "newname")

    let requests = await transport.requests
    #expect(requests[0].path == "/v1.47/containers/c/start")
    #expect(requests[0].method == .post)
    #expect(requests[1].path == "/v1.47/containers/c/stop")
    #expect(requests[1].query.contains(URLQueryItem(name: "t", value: "5")))
    #expect(requests[2].path == "/v1.47/containers/c/restart")
    // restart with nil timeout -> no t query item
    #expect(requests[2].query.isEmpty)
    #expect(requests[3].query.contains(URLQueryItem(name: "signal", value: "SIGKILL")))
    #expect(requests[4].path == "/v1.47/containers/c/pause")
    #expect(requests[5].path == "/v1.47/containers/c/unpause")
    #expect(requests[6].query.contains(URLQueryItem(name: "name", value: "newname")))
}

@Test func killContainerWithoutSignalSendsNoQuery() async throws {
    let transport = MockTransport(responder: { _ in
        DockerResponse(status: 204, headers: [:], body: Data())
    })
    let client = DockerClient(transport: transport)
    try await client.killContainer(id: "c")
    let request = await transport.last
    #expect(request?.query.isEmpty == true)
}

@Test func removeContainerEncodesForceAndVolumeFlags() async throws {
    let transport = MockTransport(responder: { _ in
        DockerResponse(status: 204, headers: [:], body: Data())
    })
    let client = DockerClient(transport: transport)
    try await client.removeContainer(id: "c", force: true, removeVolumes: true)
    let request = await transport.last
    #expect(request?.method == .delete)
    #expect(request?.query.contains(URLQueryItem(name: "force", value: "true")) == true)
    #expect(request?.query.contains(URLQueryItem(name: "v", value: "true")) == true)
}

// MARK: - Images endpoints

@Test func listImagesDecodesSummaries() async throws {
    let json = """
    [{"Id":"sha256:abcdef0123456789","ParentId":"","RepoTags":["nginx:latest"],
      "RepoDigests":["nginx@sha256:dd"],"Created":1609459200,"Size":1000000,
      "SharedSize":-1,"Containers":2,"Labels":{}},
     {"Id":"sha256:zzzz","RepoTags":["<none>:<none>"],"Created":0,"Size":5}]
    """
    let transport = MockTransport(responder: { _ in jsonResponse(json) })
    let client = DockerClient(transport: transport)
    let images = try await client.listImages()
    #expect(images.count == 2)
    #expect(images[0].displayName == "nginx:latest")
    #expect(images[0].shortID == "abcdef012345")
    #expect(images[0].createdDate == Date(timeIntervalSince1970: 1_609_459_200))
    #expect(!images[0].sizeDisplay.isEmpty)
    // Untagged image falls back to "<short> <none>".
    #expect(images[1].displayName == "zzzz <none>")
    let request = await transport.last
    #expect(request?.path == "/v1.47/images/json")
}

@Test func removeImageEncodesForce() async throws {
    let transport = MockTransport(responder: { _ in jsonResponse("[]") })
    let client = DockerClient(transport: transport)
    try await client.removeImage(id: "img", force: true)
    let request = await transport.last
    #expect(request?.method == .delete)
    #expect(request?.path == "/v1.47/images/img")
    #expect(request?.query.contains(URLQueryItem(name: "force", value: "true")) == true)
}

@Test func rawInspectImageReturnsBody() async throws {
    let transport = MockTransport(responder: { _ in jsonResponse(#"{"Id":"x"}"#) })
    let client = DockerClient(transport: transport)
    let data = try await client.rawInspectImage(id: "x")
    #expect(String(decoding: data, as: UTF8.self) == #"{"Id":"x"}"#)
    let request = await transport.last
    #expect(request?.path == "/v1.47/images/x/json")
}

@Test func imageHistoryDecodesEntries() async throws {
    let json = """
    [{"Id":"layer1","Created":1609459200,"CreatedBy":"RUN x","Size":100,
      "Comment":"c","Tags":["a:b"]},
     {"Created":0,"CreatedBy":"","Size":0,"Comment":""}]
    """
    let transport = MockTransport(responder: { _ in jsonResponse(json) })
    let client = DockerClient(transport: transport)
    let history = try await client.imageHistory(id: "img")
    #expect(history.count == 2)
    #expect(history[0].id == "layer1")
    #expect(history[0].tags == ["a:b"])
    #expect(history[0].createdDate == Date(timeIntervalSince1970: 1_609_459_200))
    #expect(history[1].id == "")
    #expect(history[1].tags == [])
    let request = await transport.last
    #expect(request?.path == "/v1.47/images/img/history")
}

@Test func tagImageEncodesRepoAndTag() async throws {
    let transport = MockTransport(responder: { _ in
        DockerResponse(status: 201, headers: [:], body: Data())
    })
    let client = DockerClient(transport: transport)
    try await client.tagImage(id: "img", repo: "myrepo", tag: "v2")
    let request = await transport.last
    #expect(request?.method == .post)
    #expect(request?.path == "/v1.47/images/img/tag")
    #expect(request?.query.contains(URLQueryItem(name: "repo", value: "myrepo")) == true)
    #expect(request?.query.contains(URLQueryItem(name: "tag", value: "v2")) == true)
}

@Test func pruneImagesEncodesDanglingFilter() async throws {
    let transport = MockTransport(responder: { _ in
        jsonResponse(#"{"ImagesDeleted":[{"Deleted":"x"}],"SpaceReclaimed":99}"#)
    })
    let client = DockerClient(transport: transport)
    let result = try await client.pruneImages(dangling: true)
    #expect(result.deletedCount == 1)
    #expect(result.spaceReclaimed == 99)
    let request = await transport.last
    let filters = request?.query.first { $0.name == "filters" }?.value
    #expect(filters?.contains("dangling") == true)
    #expect(filters?.contains("true") == true)
}

@Test func pullImageStreamsProgressAndErrorLine() async throws {
    // Success stream.
    let okStream = makeByteStream([
        #"{"status":"Pulling from library/alpine"}"# + "\n",
        #"{"id":"layer","status":"Downloading","progressDetail":{"current":50,"total":100}}"# + "\n",
        #"{"status":"Status: Downloaded newer image for alpine:3.20"}"# + "\n"
    ])
    let transport = MockTransport(streamFactory: { _ in okStream })
    let client = DockerClient(transport: transport)

    var lines: [PullProgress] = []
    for try await progress in try await client.pullImage(reference: "alpine:3.20") {
        lines.append(progress)
    }
    #expect(lines.count == 3)
    #expect(lines[1].id == "layer")
    #expect(lines[1].current == 50)
    #expect(lines[1].total == 100)

    let request = await transport.last
    #expect(request?.path == "/v1.47/images/create")
    #expect(request?.query.contains(URLQueryItem(name: "fromImage", value: "alpine")) == true)
    #expect(request?.query.contains(URLQueryItem(name: "tag", value: "3.20")) == true)
}

@Test func pullImageThrowsOnErrorLine() async throws {
    let errStream = makeByteStream([#"{"error":"manifest unknown"}"# + "\n"])
    let transport = MockTransport(streamFactory: { _ in errStream })
    let client = DockerClient(transport: transport)

    await #expect(throws: DockerError.self) {
        for try await _ in try await client.pullImage(reference: "nope:latest") {}
    }
}

@Test func pullImageSendsRegistryAuthHeader() async throws {
    let transport = MockTransport(streamFactory: { _ in makeByteStream([]) })
    let client = DockerClient(transport: transport)
    let auth = RegistryAuth(username: "u", password: "p", serverAddress: "reg")
    for try await _ in try await client.pullImage(reference: "img", auth: auth) {}
    let request = await transport.last
    #expect(request?.headers["X-Registry-Auth"] != nil)
}

@Test func pullImageThrowsWhenStreamStatusNot200() async throws {
    let transport = MockTransport(streamFactory: { _ in makeByteStream([], status: 500) })
    let client = DockerClient(transport: transport)
    await #expect(throws: DockerError.self) {
        _ = try await client.pullImage(reference: "img")
    }
}

// MARK: - System endpoints

@Test func systemInfoDecodes() async throws {
    let json = """
    {"Containers":5,"ContainersRunning":3,"ContainersPaused":1,"ContainersStopped":1,
     "Images":10,"ServerVersion":"24.0","Name":"host","OperatingSystem":"Linux",
     "OSType":"linux","Architecture":"aarch64","MemTotal":8000000000,"NCPU":8}
    """
    let transport = MockTransport(responder: { _ in jsonResponse(json) })
    let client = DockerClient(transport: transport)
    let info = try await client.systemInfo()
    #expect(info.containers == 5)
    #expect(info.containersRunning == 3)
    #expect(info.images == 10)
    #expect(info.serverVersion == "24.0")
    #expect(info.osType == "linux")
    #expect(info.ncpu == 8)
    #expect(info.memTotal == 8_000_000_000)
    let request = await transport.last
    #expect(request?.path == "/v1.47/info")
}

@Test func versionDecodesNestedPlatformName() async throws {
    let json = """
    {"Version":"24.0.5","ApiVersion":"1.47","MinAPIVersion":"1.24","Os":"linux",
     "Arch":"arm64","KernelVersion":"6.0","Platform":{"Name":"Docker Engine"}}
    """
    let transport = MockTransport(responder: { _ in jsonResponse(json) })
    let client = DockerClient(transport: transport)
    let version = try await client.version()
    #expect(version.version == "24.0.5")
    #expect(version.apiVersion == "1.47")
    #expect(version.platformName == "Docker Engine")
    #expect(version.minAPIVersion == "1.24")
    let request = await transport.last
    #expect(request?.path == "/v1.47/version")
}

@Test func systemVersionRoundTripsThroughEncoder() throws {
    let json = """
    {"Version":"1.0","ApiVersion":"1.47","Os":"linux","Arch":"arm64",
     "Platform":{"Name":"X"},"KernelVersion":"k","MinAPIVersion":"1.24"}
    """
    let decoded = try JSONDecoder().decode(SystemVersion.self, from: Data(json.utf8))
    let reencoded = try JSONEncoder().encode(decoded)
    let again = try JSONDecoder().decode(SystemVersion.self, from: reencoded)
    #expect(again == decoded)
    #expect(again.platformName == "X")
}

@Test func systemVersionEncodesWithoutPlatform() throws {
    let json = #"{"Version":"1.0","ApiVersion":"1.47","Os":"linux","Arch":"arm64"}"#
    let decoded = try JSONDecoder().decode(SystemVersion.self, from: Data(json.utf8))
    let reencoded = try JSONEncoder().encode(decoded)
    let object = try #require(try JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
    #expect(object["Platform"] == nil)
    #expect(object["KernelVersion"] == nil)
}

@Test func systemDFDecodesAndPath() async throws {
    let json = """
    {"LayersSize":500,"Images":[{"Size":100}],"Containers":[{"SizeRw":10}],
     "Volumes":[{"UsageData":{"Size":20}}]}
    """
    let transport = MockTransport(responder: { _ in jsonResponse(json) })
    let client = DockerClient(transport: transport)
    let df = try await client.systemDF()
    #expect(df.layersSize == 500)
    #expect(df.imagesSize == 100)
    #expect(df.containersSize == 10)
    #expect(df.volumesSize == 20)
    let request = await transport.last
    #expect(request?.path == "/v1.47/system/df")
}

@Test func pruneBuildCacheDecodes() async throws {
    let transport = MockTransport(responder: { _ in
        jsonResponse(#"{"CachesDeleted":["a","b"],"SpaceReclaimed":42}"#)
    })
    let client = DockerClient(transport: transport)
    let result = try await client.pruneBuildCache()
    #expect(result.spaceReclaimed == 42)
    let request = await transport.last
    #expect(request?.path == "/v1.47/build/prune")
    #expect(request?.method == .post)
}

// MARK: - Volumes endpoints

@Test func listVolumesUnwrapsEnvelope() async throws {
    let json = """
    {"Volumes":[{"Name":"data","Driver":"local","Mountpoint":"/m",
      "CreatedAt":"2021","Labels":{"x":"y"},"Scope":"local","Options":{},
      "UsageData":{"Size":1000,"RefCount":2}}],"Warnings":[]}
    """
    let transport = MockTransport(responder: { _ in jsonResponse(json) })
    let client = DockerClient(transport: transport)
    let volumes = try await client.listVolumes()
    #expect(volumes.count == 1)
    #expect(volumes[0].name == "data")
    #expect(volumes[0].id == "data")
    #expect(volumes[0].usageData?.size == 1000)
    #expect(volumes[0].usageData?.refCount == 2)
    let request = await transport.last
    #expect(request?.path == "/v1.47/volumes")
}

@Test func volumeDecodesDefaults() throws {
    let volume = try JSONDecoder().decode(Volume.self, from: Data(#"{"Name":"v"}"#.utf8))
    #expect(volume.driver == "")
    #expect(volume.scope == "local")
    #expect(volume.labels.isEmpty)
    #expect(volume.usageData == nil)
}

@Test func volumeListResponseDefaultsEmpty() throws {
    let response = try JSONDecoder().decode(VolumeListResponse.self, from: Data("{}".utf8))
    #expect(response.volumes.isEmpty)
    #expect(response.warnings.isEmpty)
}

@Test func volumeUsageDataDefaultsToUnknown() throws {
    let json = #"{"Name":"v","UsageData":{}}"#
    let volume = try JSONDecoder().decode(Volume.self, from: Data(json.utf8))
    #expect(volume.usageData?.size == -1)
    #expect(volume.usageData?.refCount == -1)
}

@Test func rawInspectVolumeReturnsBody() async throws {
    let transport = MockTransport(responder: { _ in jsonResponse(#"{"Name":"v"}"#) })
    let client = DockerClient(transport: transport)
    let data = try await client.rawInspectVolume(name: "v")
    #expect(String(decoding: data, as: UTF8.self) == #"{"Name":"v"}"#)
    let request = await transport.last
    #expect(request?.path == "/v1.47/volumes/v")
}

@Test func removeVolumeEncodesForce() async throws {
    let transport = MockTransport(responder: { _ in
        DockerResponse(status: 204, headers: [:], body: Data())
    })
    let client = DockerClient(transport: transport)
    try await client.removeVolume(name: "v", force: true)
    let request = await transport.last
    #expect(request?.method == .delete)
    #expect(request?.path == "/v1.47/volumes/v")
    #expect(request?.query.contains(URLQueryItem(name: "force", value: "true")) == true)
}

@Test func createVolumeEncodesBodyAndDecodes() async throws {
    let transport = MockTransport(responder: { _ in
        jsonResponse(#"{"Name":"newvol","Driver":"local","Mountpoint":"/m","Scope":"local"}"#, status: 201)
    })
    let client = DockerClient(transport: transport)
    let volume = try await client.createVolume(name: "newvol", driver: "local", labels: ["a": "b"])
    #expect(volume.name == "newvol")
    let request = await transport.last
    #expect(request?.method == .post)
    #expect(request?.path == "/v1.47/volumes/create")
    let body = try #require(request?.body)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["Name"] as? String == "newvol")
    #expect(object["Driver"] as? String == "local")
    #expect((object["Labels"] as? [String: String])?["a"] == "b")
}

@Test func pruneVolumesDecodes() async throws {
    let transport = MockTransport(responder: { _ in
        jsonResponse(#"{"VolumesDeleted":["a"],"SpaceReclaimed":7}"#)
    })
    let client = DockerClient(transport: transport)
    let result = try await client.pruneVolumes()
    #expect(result.deletedCount == 1)
    #expect(result.spaceReclaimed == 7)
    let request = await transport.last
    #expect(request?.path == "/v1.47/volumes/prune")
}

// MARK: - Networks endpoints

@Test func listNetworksDecodes() async throws {
    let json = """
    [{"Id":"net0123456789abcdef","Name":"bridge","Created":"2021","Scope":"local",
      "Driver":"bridge","EnableIPv6":false,"Internal":false,"Attachable":true,
      "Ingress":false,"Labels":{"k":"v"},
      "IPAM":{"Driver":"default","Config":[{"Subnet":"172.0.0.0/16","Gateway":"172.0.0.1"}]}}]
    """
    let transport = MockTransport(responder: { _ in jsonResponse(json) })
    let client = DockerClient(transport: transport)
    let networks = try await client.listNetworks()
    #expect(networks.count == 1)
    let n = networks[0]
    #expect(n.name == "bridge")
    #expect(n.shortID == "net012345678")
    #expect(n.attachable)
    #expect(n.ipam?.driver == "default")
    #expect(n.ipam?.config.first?.subnet == "172.0.0.0/16")
    #expect(n.ipam?.config.first?.gateway == "172.0.0.1")
    let request = await transport.last
    #expect(request?.path == "/v1.47/networks")
}

@Test func networkResourceDefaults() throws {
    let network = try JSONDecoder().decode(NetworkResource.self, from: Data(#"{"Id":"n"}"#.utf8))
    #expect(network.name == "")
    #expect(network.scope == "local")
    #expect(!network.enableIPv6)
    #expect(network.ipam == nil)
    #expect(network.labels.isEmpty)
}

@Test func rawInspectNetworkReturnsBody() async throws {
    let transport = MockTransport(responder: { _ in jsonResponse(#"{"Id":"n"}"#) })
    let client = DockerClient(transport: transport)
    let data = try await client.rawInspectNetwork(id: "n")
    #expect(String(decoding: data, as: UTF8.self) == #"{"Id":"n"}"#)
    let request = await transport.last
    #expect(request?.path == "/v1.47/networks/n")
}

@Test func removeNetworkIssuesDelete() async throws {
    let transport = MockTransport(responder: { _ in
        DockerResponse(status: 204, headers: [:], body: Data())
    })
    let client = DockerClient(transport: transport)
    try await client.removeNetwork(id: "n")
    let request = await transport.last
    #expect(request?.method == .delete)
    #expect(request?.path == "/v1.47/networks/n")
}

@Test func createNetworkEncodesBodyReturnsID() async throws {
    let transport = MockTransport(responder: { _ in
        jsonResponse(#"{"Id":"newnet"}"#, status: 201)
    })
    let client = DockerClient(transport: transport)
    let id = try await client.createNetwork(name: "mynet", driver: "bridge", labels: ["a": "b"])
    #expect(id == "newnet")
    let request = await transport.last
    #expect(request?.method == .post)
    #expect(request?.path == "/v1.47/networks/create")
    let body = try #require(request?.body)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["Name"] as? String == "mynet")
    #expect(object["Driver"] as? String == "bridge")
}

@Test func pruneNetworksDecodes() async throws {
    let transport = MockTransport(responder: { _ in
        jsonResponse(#"{"NetworksDeleted":["a","b"]}"#)
    })
    let client = DockerClient(transport: transport)
    let result = try await client.pruneNetworks()
    #expect(result.deletedCount == 2)
    #expect(result.spaceReclaimed == 0)
    let request = await transport.last
    #expect(request?.path == "/v1.47/networks/prune")
}

@Test func connectContainerEncodesContainer() async throws {
    let transport = MockTransport(responder: { _ in jsonResponse("{}") })
    let client = DockerClient(transport: transport)
    try await client.connectContainer(networkID: "net", containerID: "cont")
    let request = await transport.last
    #expect(request?.method == .post)
    #expect(request?.path == "/v1.47/networks/net/connect")
    let body = try #require(request?.body)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["Container"] as? String == "cont")
}

@Test func disconnectContainerEncodesForce() async throws {
    let transport = MockTransport(responder: { _ in jsonResponse("{}") })
    let client = DockerClient(transport: transport)
    try await client.disconnectContainer(networkID: "net", containerID: "cont", force: true)
    let request = await transport.last
    #expect(request?.path == "/v1.47/networks/net/disconnect")
    let body = try #require(request?.body)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["Container"] as? String == "cont")
    #expect(object["Force"] as? Bool == true)
}

// MARK: - Containers extended endpoints

@Test func createContainerEncodesNameQueryAndBody() async throws {
    let transport = MockTransport(responder: { _ in
        jsonResponse(#"{"Id":"created123","Warnings":["w"]}"#, status: 201)
    })
    let client = DockerClient(transport: transport)
    let config = ContainerCreateRequest(
        image: "nginx",
        cmd: ["nginx"],
        env: ["A=B"],
        ports: ["80/tcp": "8080"],
        binds: ["/h:/c"],
        restartPolicy: "always",
        tty: true,
        autoRemove: true
    )
    let id = try await client.createContainer(config: config, name: "web")
    #expect(id == "created123")
    let request = await transport.last
    #expect(request?.method == .post)
    #expect(request?.path == "/v1.47/containers/create")
    #expect(request?.query.contains(URLQueryItem(name: "name", value: "web")) == true)
    let body = try #require(request?.body)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["Image"] as? String == "nginx")
    let host = try #require(object["HostConfig"] as? [String: Any])
    #expect(host["AutoRemove"] as? Bool == true)
    #expect((host["RestartPolicy"] as? [String: Any])?["Name"] as? String == "always")
    #expect(host["Binds"] as? [String] == ["/h:/c"])
}

@Test func createContainerConvenienceWithDefaultsOmitsHostConfigFields() async throws {
    let transport = MockTransport(responder: { _ in
        jsonResponse(#"{"Id":"x"}"#, status: 201)
    })
    let client = DockerClient(transport: transport)
    // restartPolicy "no", no ports, no binds, no autoRemove -> nil fields.
    let config = ContainerCreateRequest(image: "alpine")
    _ = try await client.createContainer(config: config)
    let request = await transport.last
    #expect(request?.query.isEmpty == true)
    let body = try #require(request?.body)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let host = object["HostConfig"] as? [String: Any]
    #expect(host?["RestartPolicy"] == nil)
    #expect(host?["Binds"] == nil)
    #expect(object["ExposedPorts"] == nil)
}

@Test func containerCreateRequestNetworkingConfigEncodes() throws {
    let config = ContainerCreateRequest(
        image: "nginx",
        networkingConfig: .init(endpointsConfig: ["mynet": .init(aliases: ["web"])])
    )
    let data = try JSONEncoder().encode(config)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let net = try #require(object["NetworkingConfig"] as? [String: Any])
    let endpoints = try #require(net["EndpointsConfig"] as? [String: Any])
    let mynet = try #require(endpoints["mynet"] as? [String: Any])
    #expect(mynet["Aliases"] as? [String] == ["web"])
}

@Test func commitContainerEncodesQueryAndReturnsID() async throws {
    let transport = MockTransport(responder: { _ in
        jsonResponse(#"{"Id":"newimg"}"#, status: 201)
    })
    let client = DockerClient(transport: transport)
    let id = try await client.commitContainer(id: "c", repo: "r", tag: "t", comment: "msg")
    #expect(id == "newimg")
    let request = await transport.last
    #expect(request?.path == "/v1.47/commit")
    #expect(request?.query.contains(URLQueryItem(name: "container", value: "c")) == true)
    #expect(request?.query.contains(URLQueryItem(name: "repo", value: "r")) == true)
    #expect(request?.query.contains(URLQueryItem(name: "tag", value: "t")) == true)
    #expect(request?.query.contains(URLQueryItem(name: "comment", value: "msg")) == true)
}

@Test func commitContainerWithoutCommentOmitsQuery() async throws {
    let transport = MockTransport(responder: { _ in
        jsonResponse(#"{"Id":"i"}"#, status: 201)
    })
    let client = DockerClient(transport: transport)
    _ = try await client.commitContainer(id: "c", repo: "r", tag: "t")
    let request = await transport.last
    #expect(request?.query.contains { $0.name == "comment" } == false)
}

@Test func exportContainerReturnsStream() async throws {
    let transport = MockTransport(streamFactory: { _ in makeByteStream(["tarbytes"]) })
    let client = DockerClient(transport: transport)
    let stream = try await client.exportContainer(id: "c")
    #expect(stream.status == 200)
    var collected = Data()
    for try await chunk in stream.bytes { collected.append(chunk) }
    #expect(String(decoding: collected, as: UTF8.self) == "tarbytes")
    let request = await transport.last
    #expect(request?.path == "/v1.47/containers/c/export")
}

@Test func exportContainerThrowsOnBadStatus() async throws {
    let transport = MockTransport(streamFactory: { _ in makeByteStream([], status: 404) })
    let client = DockerClient(transport: transport)
    await #expect(throws: DockerError.self) {
        _ = try await client.exportContainer(id: "c")
    }
}

@Test func containerProcessesDecodesTop() async throws {
    let json = """
    {"Titles":["UID","PID","CMD"],"Processes":[["root","1","sh"],["root","2","sleep"]]}
    """
    let transport = MockTransport(responder: { _ in jsonResponse(json) })
    let client = DockerClient(transport: transport)
    let top = try await client.containerProcesses(id: "c")
    #expect(top.titles == ["UID", "PID", "CMD"])
    #expect(top.processes.count == 2)
    #expect(top.processes[0] == ["root", "1", "sh"])
    let request = await transport.last
    #expect(request?.path == "/v1.47/containers/c/top")
}

@Test func containerTopNullProcessesDefaultsEmpty() throws {
    let top = try JSONDecoder().decode(ContainerTop.self, from: Data(#"{"Titles":["X"],"Processes":null}"#.utf8))
    #expect(top.titles == ["X"])
    #expect(top.processes.isEmpty)
}

@Test func containerTopMemberwiseInit() {
    let top = ContainerTop(titles: ["A"], processes: [["1"]])
    #expect(top.titles == ["A"])
    #expect(top.processes == [["1"]])
}

@Test func updateRestartPolicyEncodesBody() async throws {
    let transport = MockTransport(responder: { _ in jsonResponse("{}") })
    let client = DockerClient(transport: transport)
    try await client.updateRestartPolicy(id: "c", policy: "on-failure", maxRetries: 3)
    let request = await transport.last
    #expect(request?.path == "/v1.47/containers/c/update")
    let body = try #require(request?.body)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let policy = try #require(object["RestartPolicy"] as? [String: Any])
    #expect(policy["Name"] as? String == "on-failure")
    #expect(policy["MaximumRetryCount"] as? Int == 3)
}

@Test func pruneContainersDecodes() async throws {
    let transport = MockTransport(responder: { _ in
        jsonResponse(#"{"ContainersDeleted":["a","b","c"],"SpaceReclaimed":300}"#)
    })
    let client = DockerClient(transport: transport)
    let result = try await client.pruneContainers()
    #expect(result.deletedCount == 3)
    #expect(result.spaceReclaimed == 300)
    let request = await transport.last
    #expect(request?.path == "/v1.47/containers/prune")
}

@Test func waitContainerReturnsExitCode() async throws {
    let transport = MockTransport(responder: { _ in jsonResponse(#"{"StatusCode":137}"#) })
    let client = DockerClient(transport: transport)
    let code = try await client.waitContainer(id: "c")
    #expect(code == 137)
    let request = await transport.last
    #expect(request?.path == "/v1.47/containers/c/wait")
}

// MARK: - Archive endpoints

@Test func statPathDecodesHeader() async throws {
    let dirMode: UInt32 = 1 << 31 | 0o755
    let statJSON = """
    {"name":"etc","size":4096,"mode":\(dirMode),"mtime":"2021","linkTarget":""}
    """
    let headerValue = Data(statJSON.utf8).base64EncodedString()
    let transport = MockTransport(responder: { _ in
        DockerResponse(status: 200, headers: ["X-Docker-Container-Path-Stat": headerValue], body: Data())
    })
    let client = DockerClient(transport: transport)
    let stat = try await client.statPath(containerID: "c", path: "/etc")
    #expect(stat.name == "etc")
    #expect(stat.isDirectory)
    let request = await transport.last
    #expect(request?.method == .head)
    #expect(request?.query.contains(URLQueryItem(name: "path", value: "/etc")) == true)
}

@Test func statPathCaseInsensitiveHeaderLookup() async throws {
    let statJSON = #"{"name":"f","size":1,"mode":0,"mtime":"","linkTarget":""}"#
    let headerValue = Data(statJSON.utf8).base64EncodedString()
    let transport = MockTransport(responder: { _ in
        // lowercase header key exercises the case-insensitive fallback.
        DockerResponse(status: 200, headers: ["x-docker-container-path-stat": headerValue], body: Data())
    })
    let client = DockerClient(transport: transport)
    let stat = try await client.statPath(containerID: "c", path: "/f")
    #expect(stat.name == "f")
}

@Test func statPathThrowsWhenHeaderMissing() async throws {
    let transport = MockTransport(responder: { _ in
        DockerResponse(status: 200, headers: [:], body: Data())
    })
    let client = DockerClient(transport: transport)
    await #expect(throws: DockerError.self) {
        _ = try await client.statPath(containerID: "c", path: "/x")
    }
}

@Test func statPathThrowsOnInvalidBase64() async throws {
    let transport = MockTransport(responder: { _ in
        DockerResponse(status: 200, headers: ["X-Docker-Container-Path-Stat": "!!!notbase64!!!"], body: Data())
    })
    let client = DockerClient(transport: transport)
    await #expect(throws: DockerError.self) {
        _ = try await client.statPath(containerID: "c", path: "/x")
    }
}

@Test func downloadArchiveReturnsStream() async throws {
    let transport = MockTransport(streamFactory: { _ in makeByteStream(["data"]) })
    let client = DockerClient(transport: transport)
    let stream = try await client.downloadArchive(containerID: "c", path: "/etc")
    #expect(stream.status == 200)
    let request = await transport.last
    #expect(request?.path == "/v1.47/containers/c/archive")
    #expect(request?.query.contains(URLQueryItem(name: "path", value: "/etc")) == true)
}

@Test func downloadArchiveThrowsOnBadStatus() async throws {
    let transport = MockTransport(streamFactory: { _ in makeByteStream([], status: 404) })
    let client = DockerClient(transport: transport)
    await #expect(throws: DockerError.self) {
        _ = try await client.downloadArchive(containerID: "c", path: "/missing")
    }
}

@Test func uploadArchivePutsTar() async throws {
    let transport = MockTransport(responder: { _ in jsonResponse("", status: 200) })
    let client = DockerClient(transport: transport)
    try await client.uploadArchive(containerID: "c", path: "/dest", tar: Data([1, 2, 3]))
    let request = await transport.last
    #expect(request?.method == .put)
    #expect(request?.path == "/v1.47/containers/c/archive")
    #expect(request?.headers["Content-Type"] == "application/x-tar")
    #expect(request?.body == Data([1, 2, 3]))
}

// MARK: - Streaming endpoints

@Test func containerStatsOnceDecodesSingleSample() async throws {
    let json = """
    {"read":"2021-01-01T00:00:00Z","memory_stats":{"usage":9000000,"limit":100000000},
     "cpu_stats":{"cpu_usage":{"total_usage":1000},"system_cpu_usage":2000,"online_cpus":4},
     "precpu_stats":{"cpu_usage":{"total_usage":500},"system_cpu_usage":1000}}
    """
    let transport = MockTransport(responder: { _ in jsonResponse(json) })
    let client = DockerClient(transport: transport)
    let sample = try await client.containerStatsOnce(id: "c")
    #expect(sample.memoryUsageBytes >= 0)
    let request = await transport.last
    #expect(request?.path == "/v1.47/containers/c/stats")
    #expect(request?.query.contains(URLQueryItem(name: "one-shot", value: "true")) == true)
}

@Test func eventsStreamYieldsEvents() async throws {
    let stream = makeByteStream([
        #"{"Type":"container","Action":"start","Actor":{"ID":"abc","Attributes":{"name":"web"}},"time":1609459200}"# + "\n"
    ])
    let transport = MockTransport(streamFactory: { _ in stream })
    let client = DockerClient(transport: transport)
    var events: [DockerEvent] = []
    for try await event in try await client.events() {
        events.append(event)
    }
    #expect(events.count == 1)
    let request = await transport.last
    #expect(request?.path == "/v1.47/events")
}

@Test func eventsThrowsOnBadStatus() async throws {
    let transport = MockTransport(streamFactory: { _ in makeByteStream([], status: 500) })
    let client = DockerClient(transport: transport)
    await #expect(throws: DockerError.self) {
        _ = try await client.events()
    }
}

@Test func containerLogsStreamThrowsOnBadStatus() async throws {
    let transport = MockTransport(streamFactory: { _ in makeByteStream([], status: 404) })
    let client = DockerClient(transport: transport)
    await #expect(throws: DockerError.self) {
        _ = try await client.containerLogs(id: "c", tty: true)
    }
}

@Test func containerStatsStreamThrowsOnBadStatus() async throws {
    let transport = MockTransport(streamFactory: { _ in makeByteStream([], status: 500) })
    let client = DockerClient(transport: transport)
    await #expect(throws: DockerError.self) {
        _ = try await client.containerStats(id: "c")
    }
}

@Test func containerLogsTTYStreamYieldsEntries() async throws {
    let transport = MockTransport(streamFactory: { _ in makeByteStream(["hello\n", "world\n"]) })
    let client = DockerClient(transport: transport)
    var entries: [LogEntry] = []
    for try await entry in try await client.containerLogs(id: "c", tty: true, follow: false, tail: 10) {
        entries.append(entry)
    }
    #expect(entries.count >= 1)
    let request = await transport.last
    #expect(request?.path == "/v1.47/containers/c/logs")
    #expect(request?.query.contains(URLQueryItem(name: "tail", value: "10")) == true)
}

@Test func containerLogsTailAllWhenNil() async throws {
    let transport = MockTransport(streamFactory: { _ in makeByteStream([]) })
    let client = DockerClient(transport: transport)
    for try await _ in try await client.containerLogs(id: "c", tty: true, tail: nil, since: 100) {}
    let request = await transport.last
    #expect(request?.query.contains(URLQueryItem(name: "tail", value: "all")) == true)
    #expect(request?.query.contains(URLQueryItem(name: "since", value: "100")) == true)
}

// MARK: - Client handshake / error mapping

@Test func negotiateDowngradesVersionPrefixForOldDaemon() async throws {
    let transport = MockTransport(responder: { request in
        if request.path == "/version" {
            return jsonResponse(#"{"Version":"19.03","ApiVersion":"1.40","Os":"linux","Arch":"amd64"}"#)
        }
        return jsonResponse("[]")
    })
    let client = DockerClient(transport: transport)
    let version = try await client.negotiate()
    #expect(version.apiVersion == "1.40")

    // Subsequent versioned call should use the downgraded prefix.
    _ = try await client.listContainers()
    let last = await transport.last
    #expect(last?.path == "/v1.40/containers/json")
}

@Test func negotiateKeepsPrefixForNewerDaemon() async throws {
    let transport = MockTransport(responder: { request in
        if request.path == "/version" {
            return jsonResponse(#"{"Version":"25","ApiVersion":"1.48","Os":"linux","Arch":"arm64"}"#)
        }
        return jsonResponse("[]")
    })
    let client = DockerClient(transport: transport)
    _ = try await client.negotiate()
    _ = try await client.listContainers()
    let last = await transport.last
    #expect(last?.path == "/v1.47/containers/json")
}

@Test func pingIssuesUnversionedRequest() async throws {
    let transport = MockTransport(responder: { _ in jsonResponse("OK") })
    let client = DockerClient(transport: transport)
    try await client.ping()
    let request = await transport.last
    #expect(request?.path == "/_ping")
}

@Test func parseAPIVersionHandlesValidAndInvalid() {
    #expect(DockerClient.parseAPIVersion("1.47")?.major == 1)
    #expect(DockerClient.parseAPIVersion("1.47")?.minor == 47)
    #expect(DockerClient.parseAPIVersion("bad") == nil)
    #expect(DockerClient.parseAPIVersion("1.2.3") == nil)
    #expect(DockerClient.parseAPIVersion("x.y") == nil)
}

@Test func apiErrorMapsDaemonMessage() async throws {
    let transport = MockTransport(responder: { _ in
        jsonResponse(#"{"message":"no such container"}"#, status: 404)
    })
    let client = DockerClient(transport: transport)
    await #expect(throws: DockerError.self) {
        _ = try await client.inspectContainer(id: "missing")
    }
}

@Test func dockerErrorMessageFallsBackToRawTextThenFallback() {
    let plain = DockerError.message(fromBody: Data("boom".utf8), fallback: "fb")
    #expect(plain == "boom")
    let empty = DockerError.message(fromBody: Data(), fallback: "fb")
    #expect(empty == "fb")
    let structured = DockerError.message(fromBody: Data(#"{"message":"m"}"#.utf8), fallback: "fb")
    #expect(structured == "m")
}

@Test func dockerErrorDescriptionsAreNonEmpty() {
    let errors: [DockerError] = [
        .socketNotFound,
        .connectionFailed("x"),
        .apiError(status: 500, message: "m"),
        .decodingFailed("d"),
        .streamClosed,
        .cancelled
    ]
    for error in errors {
        #expect(error.errorDescription?.isEmpty == false)
    }
}

@Test func decodingFailureMapsToDockerError() async throws {
    // Body missing the required Id key triggers a decoding error path.
    let transport = MockTransport(responder: { _ in jsonResponse(#"{"State":{},"Config":{}}"#) })
    let client = DockerClient(transport: transport)
    await #expect(throws: DockerError.self) {
        _ = try await client.inspectContainer(id: "x")
    }
}

@Test func shutdownDelegatesToTransport() async {
    let transport = MockTransport()
    let client = DockerClient(transport: transport)
    await client.shutdown()
}

// MARK: - PullProgress encoding round-trip

@Test func pullProgressEncodesProgressDetail() throws {
    let progress = PullProgress(id: "layer", status: "Downloading", current: 10, total: 100)
    let data = try JSONEncoder().encode(progress)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["id"] as? String == "layer")
    #expect(object["status"] as? String == "Downloading")
    let detail = try #require(object["progressDetail"] as? [String: Any])
    #expect(detail["current"] as? Int == 10)
    #expect(detail["total"] as? Int == 100)
}

@Test func pullProgressOmitsProgressDetailWhenNoBytes() throws {
    let progress = PullProgress(status: "Waiting")
    let data = try JSONEncoder().encode(progress)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["progressDetail"] == nil)
}

@Test func pullProgressDecodesErrorLine() throws {
    let progress = try JSONDecoder().decode(PullProgress.self, from: Data(#"{"error":"bad"}"#.utf8))
    #expect(progress.error == "bad")
    #expect(progress.current == nil)
}
