import Foundation
import Testing
@testable import DockerKit

// Fixtures captured verbatim from `container` CLI 1.0.0 on macOS 26.
//
// 1.0 restructured every list/inspect shape: resources nest their fields under
// `configuration`, the container `status` became an object `{state,
// startedDate, networks}`, images expose a scheme-less top-level `id` with size
// in integer `variants[].size` (no localized `fullSize`), and all dates are RFC
// 3339 strings. These tests assert the bridge still produces the Docker shape.

private let imagesListFixture1_0 = Data("""
[{"configuration":{"creationDate":"2025-10-08T11:10:40Z","descriptor":{"digest":"sha256:6baf43584bcb78f2e5847d1de515f23499913ac9f12bdf834811a3145eb11ca1","mediaType":"application/vnd.oci.image.index.v1+json","size":8077},"name":"docker.io/library/alpine:3.19"},"id":"6baf43584bcb78f2e5847d1de515f23499913ac9f12bdf834811a3145eb11ca1","variants":[{"digest":"sha256:5cd72f301a291887075a70d8b14aed6ee228fc9fd8f65e1e7eaa072f2115efd6","platform":{"architecture":"arm64","os":"linux","variant":"v8"},"size":3360923}]},{"configuration":{"creationDate":"2026-04-15T20:01:25Z","descriptor":{"digest":"sha256:8b1e78743a03dbb2c95171cc58639fef29abc8816598e27fb910ed2e621e589a","mediaType":"application/vnd.oci.image.index.v1+json","size":10333},"name":"docker.io/library/nginx:alpine"},"id":"8b1e78743a03dbb2c95171cc58639fef29abc8816598e27fb910ed2e621e589a","variants":[{"size":12000000},{"size":14000000}]}]
""".utf8)

private let containersListFixture1_0 = Data("""
[{"configuration":{"creationDate":"2026-06-09T08:28:05Z","id":"gantry-t1","image":{"descriptor":{"digest":"sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11","mediaType":"application/vnd.oci.image.index.v1+json","size":9218},"reference":"docker.io/library/alpine:latest"},"initProcess":{"arguments":["600"],"environment":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],"executable":"sleep","terminal":false,"workingDirectory":"/"},"labels":{"com.example.role":"smoke"},"mounts":[],"networks":[{"network":"default","options":{"hostname":"gantry-t1","mtu":1280}}],"platform":{"architecture":"arm64","os":"linux"},"publishedPorts":[{"containerPort":80,"count":1,"hostAddress":"0.0.0.0","hostPort":8088,"proto":"tcp"}],"resources":{"cpus":4,"memoryInBytes":1073741824}},"id":"gantry-t1","status":{"networks":[{"hostname":"gantry-t1","ipv4Address":"192.168.65.2/24","ipv4Gateway":"192.168.65.1","macAddress":"f2:0a:f1:a3:cf:27","mtu":1280,"network":"default"}],"startedDate":"2026-06-09T08:28:08Z","state":"running"}},{"configuration":{"id":"gantry-stopped","image":{"descriptor":{"digest":"sha256:6baf","size":8077},"reference":"docker.io/library/alpine:3.19"},"initProcess":{"arguments":["99"],"environment":[],"executable":"sleep","terminal":false,"workingDirectory":"/"},"labels":{},"mounts":[],"publishedPorts":[],"resources":{"cpus":4,"memoryInBytes":1073741824}},"id":"gantry-stopped","status":{"networks":[],"state":"stopped"}}]
""".utf8)

private let networksListFixture1_0 = Data("""
[{"configuration":{"creationDate":"2026-06-06T14:47:22Z","labels":{"com.apple.container.resource.role":"builtin"},"mode":"nat","name":"default","options":{"variant":"reserved"},"plugin":"container-network-vmnet"},"id":"default","status":{"ipv4Gateway":"192.168.65.1","ipv4Subnet":"192.168.65.0/24","ipv6Subnet":"fd01:4479:6552:c771::/64"}}]
""".utf8)

private let volumesListFixture1_0 = Data("""
[{"configuration":{"creationDate":"2026-06-09T08:27:30Z","driver":"local","format":"ext4","labels":{"a":"b"},"name":"gantry-test-vol","options":{},"sizeInBytes":549755813888,"source":"/Users/test/Library/Application Support/com.apple.container/volumes/gantry-test-vol/volume.img"},"id":"gantry-test-vol"}]
""".utf8)

private let statsFixture1_0 = Data("""
[{"blockReadBytes":6070272,"blockWriteBytes":0,"cpuUsageUsec":3875,"id":"gantry-t1","memoryLimitBytes":1073741824,"memoryUsageBytes":6463488,"networkRxBytes":42210,"networkTxBytes":602,"numProcesses":1}]
""".utf8)

// MARK: - Containers

@Test func appleContainersList1_0TranslatesToDockerShape() throws {
    let body = try AppleContainerJSON.containersListBody(fromAppleList: containersListFixture1_0, all: true)
    let summaries = try JSONDecoder().decode([ContainerSummary].self, from: body)
    #expect(summaries.count == 2)

    let running = try #require(summaries.first { $0.id == "gantry-t1" })
    #expect(running.image == "docker.io/library/alpine:latest")
    #expect(running.state == .running)
    #expect(running.status == "Up")
    #expect(running.command == "sleep 600")
    #expect(running.labels["com.example.role"] == "smoke")
    // 2026-06-09T08:28:05Z, parsed from the ISO creationDate.
    #expect(running.created > 1_700_000_000)

    let port = try #require(running.ports.first)
    #expect(port.privatePort == 80)
    #expect(port.publicPort == 8088)
    #expect(port.ip == "0.0.0.0")

    let stopped = try #require(summaries.first { $0.id == "gantry-stopped" })
    #expect(stopped.state == .exited)
}

@Test func appleContainersList1_0FiltersRunningOnly() throws {
    let body = try AppleContainerJSON.containersListBody(fromAppleList: containersListFixture1_0, all: false)
    let summaries = try JSONDecoder().decode([ContainerSummary].self, from: body)
    #expect(summaries.map(\.id) == ["gantry-t1"])
}

@Test func appleInspect1_0ReadsStatusObject() throws {
    let apple = try #require(
        AppleContainerJSON.array(try AppleContainerJSON.decode(containersListFixture1_0)).first
    )
    let body = try AppleContainerJSON.containerInspectBody(fromAppleInspect: apple)
    let details = try JSONDecoder().decode(ContainerDetails.self, from: body)

    #expect(details.id == "gantry-t1")
    #expect(details.state.status == .running)
    #expect(details.state.running)
    #expect(details.config.image == "docker.io/library/alpine:latest")
    #expect(details.config.cmd == ["sleep", "600"])
    // Runtime networks now live under status.networks.
    #expect(details.networkSettings.ipAddress == "192.168.65.2")
    #expect(details.hostConfig.memory == 1_073_741_824)
}

// MARK: - Images

@Test func appleImagesList1_0Translates() throws {
    let body = try AppleContainerJSON.imagesListBody(fromAppleList: imagesListFixture1_0)
    let images = try JSONDecoder().decode([ImageSummary].self, from: body)
    #expect(images.count == 2)

    let pinned = try #require(images.first { $0.repoTags.contains("alpine:3.19") })
    // Id keeps the sha256: scheme from the descriptor digest.
    #expect(pinned.id == "sha256:6baf43584bcb78f2e5847d1de515f23499913ac9f12bdf834811a3145eb11ca1")
    // Size is the sum of variants[].size (no localized fullSize in 1.0).
    #expect(pinned.size == 3_360_923)
    #expect(pinned.created > 1_700_000_000)

    let nginx = try #require(images.first { $0.repoTags.contains("nginx:alpine") })
    #expect(nginx.size == 26_000_000)
}

@Test func imageReference1_0ResolvesNestedShape() {
    let digest = "sha256:6baf43584bcb78f2e5847d1de515f23499913ac9f12bdf834811a3145eb11ca1"
    #expect(
        AppleContainerJSON.imageReference(forID: digest, inAppleList: imagesListFixture1_0)
            == "docker.io/library/alpine:3.19"
    )
    // A scheme-less hex id (1.0's top-level `id`) also resolves.
    let bareID = "8b1e78743a03dbb2c95171cc58639fef29abc8816598e27fb910ed2e621e589a"
    #expect(
        AppleContainerJSON.imageReference(forID: bareID, inAppleList: imagesListFixture1_0)
            == "docker.io/library/nginx:alpine"
    )
}

// MARK: - Volumes

@Test func appleVolumesList1_0Translates() throws {
    let body = try AppleContainerJSON.volumesListBody(fromAppleList: volumesListFixture1_0)
    let response = try JSONDecoder().decode(VolumeListResponse.self, from: body)
    let volume = try #require(response.volumes.first)
    #expect(volume.name == "gantry-test-vol")
    #expect(volume.driver == "local")
    #expect(volume.mountpoint.hasSuffix("volume.img"))
    #expect(volume.labels == ["a": "b"])
    #expect(volume.createdAt.hasPrefix("2026-06-09T"))
    #expect(volume.usageData?.size == 549_755_813_888)
}

// MARK: - Networks

@Test func appleNetworksList1_0Translates() throws {
    let body = try AppleContainerJSON.networksListBody(fromAppleList: networksListFixture1_0)
    let networks = try JSONDecoder().decode([NetworkResource].self, from: body)
    let network = try #require(networks.first)
    #expect(network.id == "default")
    #expect(network.name == "default")
    #expect(network.driver == "nat")
    #expect(network.enableIPv6)
    let subnet = try #require(network.ipam?.config.first)
    #expect(subnet.subnet == "192.168.65.0/24")
    #expect(subnet.gateway == "192.168.65.1")
}

// MARK: - Stats

@Test func appleStats1_0Translates() throws {
    let entry = try #require(
        try AppleContainerJSON.statsEntry(forID: "gantry-t1", inAppleStats: statsFixture1_0)
    )
    let body = try AppleContainerJSON.statsBody(
        fromAppleStats: entry, onlineCPUs: 4, monotonicNanoseconds: 1_000_000_000
    )
    let json = try #require(try AppleContainerJSON.decode(body) as? [String: Any])
    let memory = AppleContainerJSON.object(json["memory_stats"])
    #expect(AppleContainerJSON.int64(memory["usage"]) == 6_463_488)
    #expect(AppleContainerJSON.int64(memory["limit"]) == 1_073_741_824)
}
