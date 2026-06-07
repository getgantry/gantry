import Foundation
import Testing
@testable import DockerKit

// Fixtures captured from `container` CLI 0.12.3 on macOS 26.5.

private let containersListFixture = Data("""
[{"networks":[{"mtu":1280,"ipv4Gateway":"192.168.64.1","macAddress":"f2:29:10:2d:aa:f5","hostname":"gantry-smoke","ipv6Address":"fdd8:3480:c3b9:586f:f029:10ff:fe2d:aaf5/64","ipv4Address":"192.168.64.2/24","network":"default"}],"startedDate":802450114.597753,"status":"running","configuration":{"sysctls":{},"publishedPorts":[{"hostPort":8088,"count":1,"containerPort":80,"hostAddress":"127.0.0.1","proto":"tcp"}],"runtimeHandler":"container-runtime-linux","image":{"reference":"docker.io/library/alpine:latest","descriptor":{"size":9218,"mediaType":"application/vnd.oci.image.index.v1+json","digest":"sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11"}},"labels":{"com.example.role":"smoke"},"virtualization":false,"dns":{"searchDomains":[],"options":[],"nameservers":[]},"platform":{"os":"linux","architecture":"arm64"},"ssh":false,"rosetta":false,"capAdd":[],"readOnly":false,"publishedSockets":[],"networks":[{"options":{"hostname":"gantry-smoke","mtu":1280},"network":"default"}],"initProcess":{"terminal":false,"executable":"sleep","workingDirectory":"/","rlimits":[],"environment":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],"user":{"id":{"gid":0,"uid":0}},"arguments":["600"],"supplementalGroups":[]},"id":"gantry-smoke","mounts":[],"capDrop":[],"useInit":false,"resources":{"cpus":4,"memoryInBytes":1073741824}}},{"status":"stopped","configuration":{"id":"gantry-stopped","image":{"reference":"docker.io/library/alpine:3.19","descriptor":{"size":8077,"mediaType":"application/vnd.oci.image.index.v1+json","digest":"sha256:6baf"}},"labels":{},"publishedPorts":[],"initProcess":{"terminal":false,"executable":"sleep","arguments":["99"],"environment":[],"workingDirectory":"/"},"mounts":[],"resources":{"cpus":4,"memoryInBytes":1073741824}}}]
""".utf8)

private let imagesListFixture = Data("""
[{"fullSize":"4,2 MB","reference":"docker.io/library/alpine:latest","descriptor":{"size":9218,"digest":"sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11","mediaType":"application/vnd.oci.image.index.v1+json"}},{"fullSize":"3.4 MB","reference":"docker.io/library/alpine:3.19","descriptor":{"size":8077,"digest":"sha256:6baf43584bcb78f2e5847d1de515f23499913ac9f12bdf834811a3145eb11ca1","mediaType":"application/vnd.oci.image.index.v1+json"}}]
""".utf8)

private let volumesListFixture = Data("""
[{"format":"ext4","options":{},"name":"gantry-test-vol","driver":"local","createdAt":802450492.371705,"sizeInBytes":549755813888,"labels":{"a":"b"},"source":"/Users/test/Library/Application Support/com.apple.container/volumes/gantry-test-vol/volume.img"}]
""".utf8)

private let networksListFixture = Data("""
[{"config":{"mode":"nat","id":"default","creationDate":802450042.708275,"labels":{"com.apple.container.resource.role":"builtin"},"pluginInfo":{"variant":"reserved","plugin":"container-network-vmnet"}},"state":"running","status":{"ipv6Subnet":"fdd8:3480:c3b9:586f::/64","ipv4Subnet":"192.168.64.0/24","ipv4Gateway":"192.168.64.1"},"id":"default"}]
""".utf8)

private let statsFixture = Data("""
[{"id":"gantry-smoke","memoryUsageBytes":7499776,"memoryLimitBytes":1073741824,"cpuUsageUsec":4238,"blockReadBytes":7139328,"numProcesses":1,"blockWriteBytes":0,"networkRxBytes":40960,"networkTxBytes":602}]
""".utf8)

private let dfFixture = Data("""
{"containers":{"active":1,"reclaimable":0,"sizeInBytes":266944512,"total":1},"images":{"active":1,"reclaimable":172003328,"sizeInBytes":250732544,"total":2},"volumes":{"active":0,"reclaimable":0,"sizeInBytes":0,"total":0}}
""".utf8)

// MARK: - Containers

@Test func appleContainersListTranslatesToDockerShape() throws {
    let body = try AppleContainerJSON.containersListBody(fromAppleList: containersListFixture, all: true)
    let summaries = try JSONDecoder().decode([ContainerSummary].self, from: body)
    #expect(summaries.count == 2)

    let running = try #require(summaries.first { $0.id == "gantry-smoke" })
    #expect(running.displayName == "gantry-smoke")
    #expect(running.image == "docker.io/library/alpine:latest")
    #expect(running.state == .running)
    #expect(running.status == "Up")
    #expect(running.command == "sleep 600")
    #expect(running.labels["com.example.role"] == "smoke")
    // startedDate is apple-epoch; 802450114 + 978307200 = 1780757314.
    #expect(running.created == 1_780_757_314)

    let port = try #require(running.ports.first)
    #expect(port.privatePort == 80)
    #expect(port.publicPort == 8088)
    #expect(port.ip == "127.0.0.1")
    #expect(port.type == "tcp")

    let stopped = try #require(summaries.first { $0.id == "gantry-stopped" })
    #expect(stopped.state == .exited)
    #expect(stopped.created == 0)
}

@Test func appleContainersListFiltersRunningOnly() throws {
    let body = try AppleContainerJSON.containersListBody(fromAppleList: containersListFixture, all: false)
    let summaries = try JSONDecoder().decode([ContainerSummary].self, from: body)
    #expect(summaries.map(\.id) == ["gantry-smoke"])
}

@Test func appleInspectTranslatesToContainerDetails() throws {
    let apple = try #require(
        AppleContainerJSON.array(try AppleContainerJSON.decode(containersListFixture)).first
    )
    let body = try AppleContainerJSON.containerInspectBody(fromAppleInspect: apple)
    let details = try JSONDecoder().decode(ContainerDetails.self, from: body)

    #expect(details.id == "gantry-smoke")
    #expect(details.displayName == "gantry-smoke")
    #expect(details.state.status == .running)
    #expect(details.state.running)
    #expect(details.config.tty == false)
    #expect(details.config.image == "docker.io/library/alpine:latest")
    #expect(details.config.cmd == ["sleep", "600"])
    #expect(details.config.env == ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"])
    #expect(details.networkSettings.ipAddress == "192.168.64.2")
    #expect(details.path == "sleep")
    #expect(details.args == ["600"])
    #expect(details.hostConfig.memory == 1_073_741_824)

    // The original CLI object rides along for the raw Inspect tab.
    let raw = try #require(try AppleContainerJSON.decode(body) as? [String: Any])
    #expect(raw["AppleContainer"] != nil)
}

@Test func appleStateMapping() {
    #expect(AppleContainerJSON.dockerState(fromAppleStatus: "running") == "running")
    #expect(AppleContainerJSON.dockerState(fromAppleStatus: "stopped") == "exited")
    #expect(AppleContainerJSON.dockerState(fromAppleStatus: "created") == "created")
    #expect(AppleContainerJSON.dockerState(fromAppleStatus: "stopping") == "removing")
    #expect(AppleContainerJSON.dockerState(fromAppleStatus: "weird") == "exited")
}

// MARK: - Images

@Test func appleImagesListTranslates() throws {
    let body = try AppleContainerJSON.imagesListBody(fromAppleList: imagesListFixture)
    let images = try JSONDecoder().decode([ImageSummary].self, from: body)
    #expect(images.count == 2)

    let latest = try #require(images.first { $0.repoTags.contains("alpine:latest") })
    #expect(latest.id == "sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11")
    // "4,2 MB" — the CLI formats sizes in the user's locale.
    #expect(latest.size == 4_200_000)

    let pinned = try #require(images.first { $0.repoTags.contains("alpine:3.19") })
    #expect(pinned.size == 3_400_000)
}

@Test func localizedByteParsing() {
    #expect(AppleContainerJSON.bytes(fromLocalizedSize: "4,2 MB") == 4_200_000)
    #expect(AppleContainerJSON.bytes(fromLocalizedSize: "4.2 MB") == 4_200_000)
    #expect(AppleContainerJSON.bytes(fromLocalizedSize: "634 KB") == 634_000)
    #expect(AppleContainerJSON.bytes(fromLocalizedSize: "1,5\u{00A0}GB") == 1_500_000_000)
    #expect(AppleContainerJSON.bytes(fromLocalizedSize: "2\u{202F}TB") == 2_000_000_000_000)
    #expect(AppleContainerJSON.bytes(fromLocalizedSize: "512 B") == 512)
    #expect(AppleContainerJSON.bytes(fromLocalizedSize: "1 MiB") == 1_048_576)
    #expect(AppleContainerJSON.bytes(fromLocalizedSize: "") == 0)
    #expect(AppleContainerJSON.bytes(fromLocalizedSize: "garbage") == 0)
}

@Test func imageReferenceResolution() {
    let digest = "sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11"
    #expect(
        AppleContainerJSON.imageReference(forID: digest, inAppleList: imagesListFixture)
            == "docker.io/library/alpine:latest"
    )
    // Plain references pass through untouched.
    #expect(
        AppleContainerJSON.imageReference(forID: "alpine:latest", inAppleList: imagesListFixture)
            == "alpine:latest"
    )
    // Unknown digests fall through unchanged.
    #expect(
        AppleContainerJSON.imageReference(forID: "sha256:dead", inAppleList: imagesListFixture)
            == "sha256:dead"
    )
}

@Test func displayReferenceStripsImplicitRegistry() {
    #expect(AppleContainerJSON.displayReference("docker.io/library/alpine:latest") == "alpine:latest")
    #expect(AppleContainerJSON.displayReference("docker.io/grafana/grafana:10") == "grafana/grafana:10")
    #expect(AppleContainerJSON.displayReference("ghcr.io/owner/tool:1") == "ghcr.io/owner/tool:1")
}

// MARK: - Volumes

@Test func appleVolumesListTranslates() throws {
    let body = try AppleContainerJSON.volumesListBody(fromAppleList: volumesListFixture)
    let response = try JSONDecoder().decode(VolumeListResponse.self, from: body)
    let volume = try #require(response.volumes.first)
    #expect(volume.name == "gantry-test-vol")
    #expect(volume.driver == "local")
    #expect(volume.mountpoint.hasSuffix("volume.img"))
    #expect(volume.labels == ["a": "b"])
    #expect(volume.createdAt.hasPrefix("2026-06-06T"))
    #expect(volume.usageData?.size == 549_755_813_888)
}

@Test func appleVolumeInspectKeepsISODate() {
    // `volume inspect` already emits an ISO string; it must pass through.
    let row = AppleContainerJSON.volumeJSON(fromAppleVolume: [
        "name": "v", "createdAt": "2026-06-06T14:54:52Z"
    ])
    #expect(row["CreatedAt"] as? String == "2026-06-06T14:54:52Z")
}

// MARK: - Networks

@Test func appleNetworksListTranslates() throws {
    let body = try AppleContainerJSON.networksListBody(fromAppleList: networksListFixture)
    let networks = try JSONDecoder().decode([NetworkResource].self, from: body)
    let network = try #require(networks.first)
    #expect(network.id == "default")
    #expect(network.name == "default")
    #expect(network.driver == "nat")
    #expect(network.enableIPv6)
    #expect(network.ipam?.config.first?.subnet == "192.168.64.0/24")
    #expect(network.ipam?.config.first?.gateway == "192.168.64.1")
    #expect(network.created.hasPrefix("2026-"))
}

// MARK: - Stats

@Test func appleStatsTranslatesCounters() throws {
    let entry = try #require(
        try AppleContainerJSON.statsEntry(forID: "gantry-smoke", inAppleStats: statsFixture)
    )
    let body = try AppleContainerJSON.statsBody(
        fromAppleStats: entry,
        onlineCPUs: 8,
        monotonicNanoseconds: 1_000_000_000_000
    )
    let sample = try JSONDecoder().decode(ContainerStatsSample.self, from: body)
    #expect(sample.memoryUsageBytes == 7_499_776)
    #expect(sample.memoryLimitBytes == 1_073_741_824)
    #expect(sample.pids == 1)
    #expect(sample.networkRxBytes == 40_960)
    #expect(sample.networkTxBytes == 602)
    #expect(sample.blockReadBytes == 7_139_328)
    #expect(sample.cpuTotalUsage == 4_238_000)  // usec → ns
    #expect(sample.systemCPUUsage == 8_000_000_000_000)  // clock × cpus
    #expect(sample.onlineCPUs == 8)
    // No precpu on the first sample: CPU% must be zero, not garbage.
    #expect(sample.cpuPercent == 0)
}

@Test func appleStatsCPUDeltaMath() throws {
    // Container burned 0.5 CPU-seconds over a 1-second window on 4 CPUs:
    // docker's formula must report 50%.
    let entry: [String: Any] = ["id": "c", "cpuUsageUsec": 1_500_000, "memoryUsageBytes": 1, "memoryLimitBytes": 2]
    let body = try AppleContainerJSON.statsBody(
        fromAppleStats: entry,
        onlineCPUs: 4,
        monotonicNanoseconds: 2_000_000_000,
        previous: (cpuTotal: 1_000_000_000, system: 4_000_000_000)
    )
    let sample = try JSONDecoder().decode(ContainerStatsSample.self, from: body)
    // cpuΔ = 0.5e9, systemΔ = (2e9×4) − 4e9 = 4e9 → 0.125 × 4 × 100 = 50%.
    #expect(abs(sample.cpuPercent - 50.0) < 0.001)
}

// MARK: - System

@Test func appleDFTranslates() throws {
    let body = try AppleContainerJSON.dfBody(fromAppleDF: dfFixture)
    let usage = try JSONDecoder().decode(SystemDiskUsage.self, from: body)
    #expect(usage.imagesCount == 2)
    #expect(usage.imagesSize == 250_732_544)
    #expect(usage.containersCount == 1)
    #expect(usage.containersSize == 266_944_512)
    #expect(usage.volumesCount == 0)
    #expect(usage.volumesSize == 0)
    #expect(usage.layersSize == 250_732_544)
}

@Test func appleVersionBody() throws {
    let body = try AppleContainerJSON.versionBody(
        appServerVersion: "container-apiserver version 0.12.3 (build: release, commit: unspeci)"
    )
    let version = try JSONDecoder().decode(SystemVersion.self, from: body)
    #expect(version.version == "0.12.3")
    #expect(version.apiVersion == "1.47")
    #expect(version.platformName == "apple/container")
}

@Test func appleInfoBody() throws {
    let body = try AppleContainerJSON.infoBody(
        containersTotal: 3,
        containersRunning: 1,
        imagesCount: 2,
        serverVersion: "container-apiserver version 0.12.3 (build: release)",
        ncpu: 10,
        memTotal: 34_359_738_368,
        hostName: "test-mac"
    )
    let info = try JSONDecoder().decode(SystemInfo.self, from: body)
    #expect(info.containers == 3)
    #expect(info.containersRunning == 1)
    #expect(info.containersStopped == 2)
    #expect(info.images == 2)
    #expect(info.serverVersion == "0.12.3")
    #expect(info.ncpu == 10)
    #expect(info.memTotal == 34_359_738_368)
    #expect(info.operatingSystem == "macOS (apple/container)")
}

// MARK: - Pull progress

@Test func pullProgressLineTranslation() throws {
    let line = "[1/2] Fetching image 15% (19 of 49 blobs, 3,4/22,2 MB, 647 KB/s) [6s]"
    let json = try #require(AppleContainerJSON.pullProgressJSON(fromCLILine: line))
    let data = try AppleContainerJSON.encode(json)
    let progress = try JSONDecoder().decode(PullProgress.self, from: data)
    #expect(progress.status == line)
    #expect(progress.current == 15)
    #expect(progress.total == 100)

    #expect(AppleContainerJSON.pullProgressJSON(fromCLILine: "   ") == nil)
    let plain = try #require(AppleContainerJSON.pullProgressJSON(fromCLILine: "[2/2] Unpacking image"))
    #expect(plain["progressDetail"] == nil)
}

// MARK: - Prune output

@Test func pruneOutputParsing() throws {
    let output = """
    gantry-old-1
    gantry-old-2
    Reclaimed 1,2 GB
    """
    let body = try AppleContainerJSON.pruneBody(fromCLIOutput: output, deletedKey: "ContainersDeleted")
    let result = try JSONDecoder().decode(PruneResult.self, from: body)
    #expect(result.deletedCount == 2)
    #expect(result.spaceReclaimed == 1_200_000_000)
}

@Test func pruneOutputEmpty() throws {
    let body = try AppleContainerJSON.pruneBody(fromCLIOutput: "", deletedKey: "VolumesDeleted")
    let result = try JSONDecoder().decode(PruneResult.self, from: body)
    #expect(result.deletedCount == 0)
    #expect(result.spaceReclaimed == 0)
}

@Test func prunedImagesCountThroughImagesDeletedShape() throws {
    let body = try AppleContainerJSON.pruneBody(
        fromCLIOutput: "sha256:aaa\nsha256:bbb\nFreed 172 MB",
        deletedKey: "ImagesDeleted"
    )
    let result = try JSONDecoder().decode(PruneResult.self, from: body)
    #expect(result.deletedCount == 2)
    #expect(result.spaceReclaimed == 172_000_000)
}

// MARK: - Processes (docker top emulation)

@Test func topParsesBusyboxPS() throws {
    let output = """
    PID   USER     TIME  COMMAND
        1 root      0:00 sleep 600
        2 root      0:00 ps aux
    """
    let body = try AppleContainerJSON.topBody(fromPSOutput: output)
    let top = try JSONDecoder().decode(ContainerTop.self, from: body)
    #expect(top.titles == ["PID", "USER", "TIME", "COMMAND"])
    #expect(top.processes.count == 2)
    #expect(top.processes[0] == ["1", "root", "0:00", "sleep 600"])
    #expect(top.processes[1] == ["2", "root", "0:00", "ps aux"])
}

@Test func topHandlesEmptyOutput() throws {
    let body = try AppleContainerJSON.topBody(fromPSOutput: "")
    let top = try JSONDecoder().decode(ContainerTop.self, from: body)
    #expect(top.titles.isEmpty)
    #expect(top.processes.isEmpty)
}

// MARK: - Routing & framing

@Test func routeStripsVersionPrefix() {
    #expect(AppleContainerTransport.route(for: "/v1.47/containers/json") == ["containers", "json"])
    #expect(AppleContainerTransport.route(for: "/containers/json") == ["containers", "json"])
    #expect(AppleContainerTransport.route(for: "/version") == ["version"])
    // A container named "v2.x" must not be mistaken for a version prefix
    // (version prefixes only appear first).
    #expect(AppleContainerTransport.route(for: "/containers/abc/json") == ["containers", "abc", "json"])
}

@Test func stdcopyFraming() {
    let framed = AppleContainerTransport.frame(Data("hi\n".utf8), stream: 1)
    #expect(framed.count == 11)
    #expect(framed[0] == 1)
    #expect(Array(framed[1...3]) == [0, 0, 0])
    #expect(Array(framed[4...7]) == [0, 0, 0, 3])  // big-endian length 3

    var demuxer = DockerLogDemuxer()
    let entries = demuxer.ingest(framed)
    #expect(entries.count == 1)
    #expect(entries.first?.text == "hi")
    #expect(entries.first?.stream == .stdout)
}
