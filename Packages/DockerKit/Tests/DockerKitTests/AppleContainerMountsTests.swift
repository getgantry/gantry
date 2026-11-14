import Foundation
import Testing
@testable import DockerKit

// `container inspect gaom-mounts` from container CLI 1.7.1 on macOS 27.2,
// for `container run -v DIR:/ro:ro -v DIR2:/rw -v gaom-data:/data --tmpfs /scratch`.
// Home paths are replaced with /Users/me.
private let appleInspectFixture = Data("""
{"configuration":{"capAdd":[],"capDrop":[],"creationDate":"2026-11-14T17:17:56Z","dns":{"nameservers":[],"options":[],"searchDomains":[]},"id":"gaom-mounts","image":{"descriptor":{"digest":"sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f","mediaType":"application/vnd.oci.image.index.v1+json","size":9218},"reference":"docker.io/library/alpine:3.22"},"initProcess":{"arguments":["3600"],"environment":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],"executable":"sleep","rlimits":[],"supplementalGroups":[],"terminal":false,"user":{"id":{"gid":0,"uid":0}},"workingDirectory":"/"},"labels":{},"mounts":[{"destination":"/scratch","options":[],"source":"tmpfs","type":{"tmpfs":{}}},{"destination":"/ro","options":["ro"],"source":"/Users/me/project/bindro","type":{"virtiofs":{}}},{"destination":"/rw","options":[],"source":"/Users/me/project/bindrw","type":{"virtiofs":{}}},{"destination":"/data","options":[],"source":"/Users/me/Library/Application Support/com.apple.container/volumes/gaom-data/volume.img","type":{"volume":{"cache":{"on":{}},"format":"ext4","name":"gaom-data","sync":{"fsync":{}}}}}],"networks":[{"network":"default","options":{"hostname":"gaom-mounts","mtu":1280}}],"platform":{"architecture":"arm64","os":"linux","variant":"v8"},"publishedPorts":[],"publishedSockets":[],"readOnly":false,"resources":{"cpuOverhead":1,"cpus":4,"memoryInBytes":1073741824},"rosetta":false,"runtimeHandler":"container-runtime-linux","ssh":false,"sysctls":{},"useInit":false,"virtualization":false},"id":"gaom-mounts","status":{"networks":[{"hostname":"gaom-mounts","ipv4Address":"192.168.64.47/24","ipv4Gateway":"192.168.64.1","ipv6Address":"fdef:458:35d1:db56:fc27:24ff:fe7d:d9b6/64","macAddress":"fe:27:24:7d:d9:b6","mtu":1280,"network":"default","variant":"reserved"}],"startedDate":"2026-11-14T17:17:57Z","state":"running"}}
""".utf8)

// `docker inspect --format '{{json .Mounts}}'` from Docker 29.6.2 for
// `docker run -v /tmp/gaom-ro:/ro:ro -v gaom-data:/data --tmpfs /scratch`.
private let dockerMountsFixture = Data("""
[{"Type":"bind","Source":"/tmp/gaom-ro","Destination":"/ro","Mode":"ro","RW":false,"Propagation":"rprivate"},{"Type":"volume","Name":"gaom-data","Source":"/var/lib/docker/volumes/gaom-data/_data","Destination":"/data","Driver":"local","Mode":"z","RW":true,"Propagation":""}]
""".utf8)

private func appleElement() throws -> [String: Any] {
    try #require(try AppleContainerJSON.decode(appleInspectFixture) as? [String: Any])
}

private func byTarget(_ mounts: [MountPoint]) -> [String: MountPoint] {
    Dictionary(uniqueKeysWithValues: mounts.map { ($0.destination, $0) })
}

@Test func appleInspectMountsAreDockerShaped() throws {
    let body = try AppleContainerJSON.containerInspectBody(fromAppleInspect: appleElement())
    let details = try JSONDecoder().decode(ContainerDetails.self, from: body)
    let mounts = byTarget(details.mounts)
    #expect(mounts.count == 4)

    let ro = try #require(mounts["/ro"])
    #expect(ro.type == "bind")
    #expect(ro.source == "/Users/me/project/bindro")
    #expect(ro.rw == false)
    #expect(ro.name == nil)

    let rw = try #require(mounts["/rw"])
    #expect(rw.type == "bind")
    #expect(rw.rw == true)

    let volume = try #require(mounts["/data"])
    #expect(volume.type == "volume")
    #expect(volume.name == "gaom-data")
    #expect(volume.source == "/Users/me/Library/Application Support/com.apple.container/volumes/gaom-data/volume.img")
    #expect(volume.rw == true)
    #expect(volume.displaySource == "gaom-data")

    let tmpfs = try #require(mounts["/scratch"])
    #expect(tmpfs.type == "tmpfs")
    #expect(tmpfs.rw == true)
}

@Test func appleListRowUsesTheSameMounts() throws {
    let list = try JSONSerialization.data(withJSONObject: [appleElement()])
    let body = try AppleContainerJSON.containersListBody(fromAppleList: list, all: true)
    let summary = try #require(try JSONDecoder().decode([ContainerSummary].self, from: body).first)
    let mounts = byTarget(summary.mounts)
    #expect(mounts["/ro"]?.rw == false)
    #expect(mounts["/data"]?.name == "gaom-data")
    #expect(mounts["/data"]?.type == "volume")
}

@Test func appleReadOnlyVolumeFromOptions() {
    let row = AppleContainerJSON.mountJSON(fromAppleMount: [
        "destination": "/data", "options": ["ro"], "source": "/v/volume.img",
        "type": ["volume": ["name": "db", "format": "ext4"]]
    ])
    #expect(row["RW"] as? Bool == false)
    #expect(row["Name"] as? String == "db")
    #expect(row["Type"] as? String == "volume")
}

@Test func appleOlderMountShapesStillWork() {
    let old = AppleContainerJSON.mountJSON(fromAppleMount: [
        "type": "virtiofs", "source": "/src", "target": "/dst", "readOnly": true
    ])
    #expect(old["Type"] as? String == "bind")
    #expect(old["Destination"] as? String == "/dst")
    #expect(old["RW"] as? Bool == false)

    let named = AppleContainerJSON.mountJSON(fromAppleMount: ["type": "volume", "name": "cache", "destination": "/c"])
    #expect(named["Name"] as? String == "cache")
    #expect(named["Source"] as? String == "cache")
    #expect(named["RW"] as? Bool == true)

    let unknown = AppleContainerJSON.mountJSON(fromAppleMount: ["type": ["block": [:]], "source": "/dev/x", "destination": "/b"])
    #expect(unknown["Type"] as? String == "block")
    #expect(unknown["Name"] == nil)
}

@Test func dockerMountsDisplaySource() throws {
    let mounts = byTarget(try JSONDecoder().decode([MountPoint].self, from: dockerMountsFixture))
    #expect(mounts["/ro"]?.displaySource == "/tmp/gaom-ro")
    #expect(mounts["/ro"]?.rw == false)
    #expect(mounts["/data"]?.displaySource == "gaom-data")
    #expect(mounts["/data"]?.rw == true)
}

@Test func displaySourceFallbacks() throws {
    let rows = try JSONDecoder().decode([MountPoint].self, from: Data("""
    [{"Type":"volume","Source":"/v/_data","Destination":"/a"},
     {"Name":"n","Source":"","Destination":"/b"},
     {"Source":"","Destination":"/c"}]
    """.utf8))
    #expect(rows.map(\.displaySource) == ["/v/_data", "n", nil])
}
