import Foundation
import Testing
@testable import DockerKit

// MARK: - TAR fixture builder

/// Builds one 512-byte ustar header block for the given member.
private func tarHeader(name: String, size: Int64, typeFlag: Character) -> [UInt8] {
    var block = [UInt8](repeating: 0, count: 512)

    func write(_ string: String, at offset: Int, max: Int) {
        let bytes = Array(string.utf8.prefix(max))
        for (index, byte) in bytes.enumerated() {
            block[offset + index] = byte
        }
    }

    // Split name into prefix (345..500) and name (0..100) when long, else name only.
    let nameBytes = Array(name.utf8)
    if nameBytes.count <= 100 {
        write(name, at: 0, max: 100)
    } else {
        // Place the first 100 bytes in name; the rest in prefix.
        let split = name.index(name.startIndex, offsetBy: name.count - 100)
        let prefix = String(name[name.startIndex ..< split])
        let tail = String(name[split...])
        write(tail, at: 0, max: 100)
        write(prefix, at: 345, max: 155)
    }

    // mode (octal, 8 bytes incl NUL) and ids.
    write("0000644", at: 100, max: 8)
    write("0000000", at: 108, max: 8)
    write("0000000", at: 116, max: 8)

    // size: 11 octal digits + NUL/space.
    let sizeOctal = String(size, radix: 8)
    let padded = String(repeating: "0", count: max(0, 11 - sizeOctal.count)) + sizeOctal
    write(padded, at: 124, max: 12)

    // mtime: a fixed known value (2021-01-01T00:00:00Z = 1609459200 = 0o13773463000).
    write("13773463000", at: 136, max: 12)

    // typeflag.
    block[156] = typeFlag.asciiValue ?? UInt8(ascii: "0")

    // ustar magic + version.
    write("ustar", at: 257, max: 6)
    write("00", at: 263, max: 2)

    // Checksum: fill field with spaces, sum all bytes, write octal.
    for i in 148 ..< 156 { block[i] = UInt8(ascii: " ") }
    let sum = block.reduce(0) { $0 + Int($1) }
    let checksum = String(sum, radix: 8)
    let checksumPadded = String(repeating: "0", count: max(0, 6 - checksum.count)) + checksum
    write(checksumPadded, at: 148, max: 6)
    block[154] = 0
    block[155] = UInt8(ascii: " ")

    return block
}

/// Appends a member (header + padded payload) to a tar byte buffer.
private func tarAppend(_ buffer: inout [UInt8], name: String, payload: [UInt8], typeFlag: Character) {
    buffer.append(contentsOf: tarHeader(name: name, size: Int64(payload.count), typeFlag: typeFlag))
    buffer.append(contentsOf: payload)
    let remainder = payload.count % 512
    if remainder != 0 {
        buffer.append(contentsOf: [UInt8](repeating: 0, count: 512 - remainder))
    }
}

@Test func tarReaderParsesMixedEntries() {
    var buffer: [UInt8] = []
    tarAppend(&buffer, name: "etc/", payload: [], typeFlag: "5")
    tarAppend(&buffer, name: "etc/hosts", payload: Array("127.0.0.1 localhost\n".utf8), typeFlag: "0")
    tarAppend(&buffer, name: "etc/conf.d/", payload: [], typeFlag: "5")
    tarAppend(&buffer, name: "etc/conf.d/app.conf", payload: Array("key=value".utf8), typeFlag: "0")
    tarAppend(&buffer, name: "etc/link", payload: [], typeFlag: "2")
    // Two zero blocks to terminate.
    buffer.append(contentsOf: [UInt8](repeating: 0, count: 1024))

    let entries = TarReader.entries(in: Data(buffer))
    #expect(entries.count == 5)

    let hosts = entries.first { $0.name == "etc/hosts" }
    #expect(hosts != nil)
    #expect(hosts?.size == 20)
    #expect(hosts?.isDirectory == false)
    #expect(hosts?.isSymlink == false)

    let dir = entries.first { $0.name == "etc/conf.d/" }
    #expect(dir?.isDirectory == true)

    let link = entries.first { $0.name == "etc/link" }
    #expect(link?.isSymlink == true)

    // mtime decoded from the octal field.
    #expect(hosts?.mtime == Date(timeIntervalSince1970: 1_609_459_200))
}

@Test func tarReaderHandlesPaxLongName() {
    let longName = "etc/" + String(repeating: "a", count: 130) + "/file.txt"
    let paxRecord = "path=\(longName)\n"
    // PAX record format: "<len> <record>" where len includes itself.
    var lengthGuess = paxRecord.utf8.count + 4
    var line = "\(lengthGuess) \(paxRecord)"
    // Adjust until the leading length equals the full record length.
    while line.utf8.count != lengthGuess {
        lengthGuess = line.utf8.count
        line = "\(lengthGuess) \(paxRecord)"
    }

    var buffer: [UInt8] = []
    tarAppend(&buffer, name: "PaxHeaders/file", payload: Array(line.utf8), typeFlag: "x")
    // The real entry carries a truncated ustar name; pax overrides it.
    tarAppend(&buffer, name: "etc/truncated", payload: Array("data".utf8), typeFlag: "0")
    buffer.append(contentsOf: [UInt8](repeating: 0, count: 1024))

    let entries = TarReader.entries(in: Data(buffer))
    #expect(entries.count == 1)
    #expect(entries[0].name == longName)
    #expect(entries[0].size == 4)
}

@Test func firstFilePayloadReturnsLeadingRegularFile() {
    var buffer: [UInt8] = []
    // A directory precedes the file; the directory must be skipped.
    tarAppend(&buffer, name: "etc/", payload: [], typeFlag: "5")
    tarAppend(&buffer, name: "etc/hosts", payload: Array("127.0.0.1 localhost\n".utf8), typeFlag: "0")
    tarAppend(&buffer, name: "etc/other", payload: Array("ignored".utf8), typeFlag: "0")
    buffer.append(contentsOf: [UInt8](repeating: 0, count: 1024))

    let payload = TarReader.firstFilePayload(in: Data(buffer))
    #expect(payload == Data("127.0.0.1 localhost\n".utf8))
}

@Test func firstFilePayloadSkipsPaxExtensionHeader() {
    let paxRecord = "path=etc/renamed\n"
    var lengthGuess = paxRecord.utf8.count + 4
    var line = "\(lengthGuess) \(paxRecord)"
    while line.utf8.count != lengthGuess {
        lengthGuess = line.utf8.count
        line = "\(lengthGuess) \(paxRecord)"
    }

    var buffer: [UInt8] = []
    tarAppend(&buffer, name: "PaxHeaders/file", payload: Array(line.utf8), typeFlag: "x")
    tarAppend(&buffer, name: "etc/truncated", payload: Array("data".utf8), typeFlag: "0")
    buffer.append(contentsOf: [UInt8](repeating: 0, count: 1024))

    #expect(TarReader.firstFilePayload(in: Data(buffer)) == Data("data".utf8))
}

@Test func firstFilePayloadReturnsNilWhenNoRegularFile() {
    var buffer: [UInt8] = []
    tarAppend(&buffer, name: "etc/", payload: [], typeFlag: "5")
    tarAppend(&buffer, name: "etc/link", payload: [], typeFlag: "2")
    buffer.append(contentsOf: [UInt8](repeating: 0, count: 1024))

    #expect(TarReader.firstFilePayload(in: Data(buffer)) == nil)
}

@Test func directoryEntriesReturnsImmediateChildren() {
    var buffer: [UInt8] = []
    tarAppend(&buffer, name: "etc/", payload: [], typeFlag: "5")
    tarAppend(&buffer, name: "etc/hosts", payload: Array("x".utf8), typeFlag: "0")
    tarAppend(&buffer, name: "etc/conf.d/", payload: [], typeFlag: "5")
    tarAppend(&buffer, name: "etc/conf.d/app.conf", payload: Array("y".utf8), typeFlag: "0")
    buffer.append(contentsOf: [UInt8](repeating: 0, count: 1024))

    let children = DockerClient.directoryEntries(fromArchive: Data(buffer))
    let names = Set(children.map(\.name))
    // Only direct children of "etc/" — the dir itself and grandchildren excluded.
    #expect(names == ["hosts", "conf.d"])
    #expect(children.first { $0.name == "conf.d" }?.isDirectory == true)
    #expect(children.first { $0.name == "hosts" }?.isDirectory == false)
}

// MARK: - X-Registry-Auth encoding

@Test func registryAuthEncodesBase64URLJSON() throws {
    let auth = RegistryAuth(username: "alice", password: "s3cr3t", serverAddress: "registry.example.com")
    let value = try auth.headerValue()

    // URL-safe alphabet only.
    #expect(!value.contains("+"))
    #expect(!value.contains("/"))

    // Round-trip: reverse the URL-safe substitution, decode, parse JSON.
    let standard = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let data = try #require(Data(base64Encoded: standard))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
    #expect(json["username"] == "alice")
    #expect(json["password"] == "s3cr3t")
    #expect(json["serveraddress"] == "registry.example.com")
}

// MARK: - Path-stat base64 decode

@Test func pathStatDecodesFromBase64Header() throws {
    // mode with the Go directory bit (1<<31) set.
    let dirMode: UInt32 = 1 << 31 | 0o755
    let json = """
    {"name":"etc","size":4096,"mode":\(dirMode),"mtime":"2021-01-01T00:00:00Z","linkTarget":""}
    """
    let base64 = Data(json.utf8).base64EncodedString()
    let decoded = try #require(Data(base64Encoded: base64))
    let stat = try JSONDecoder().decode(ContainerPathStat.self, from: decoded)

    #expect(stat.name == "etc")
    #expect(stat.size == 4096)
    #expect(stat.isDirectory)
    #expect(!stat.isSymlink)
    #expect(stat.mtime == "2021-01-01T00:00:00Z")
}

@Test func pathStatDetectsSymlink() throws {
    let linkMode: UInt32 = 1 << 27 | 0o777
    let json = #"{"name":"link","size":0,"mode":\#(linkMode),"mtime":"","linkTarget":"/real/path"}"#
    let stat = try JSONDecoder().decode(ContainerPathStat.self, from: Data(json.utf8))
    #expect(stat.isSymlink)
    #expect(!stat.isDirectory)
    #expect(stat.linkTarget == "/real/path")
}

// MARK: - Pull reference splitting

@Test func pullReferenceSplitting() {
    #expect(DockerClient.splitPullReference("alpine").fromImage == "alpine")
    #expect(DockerClient.splitPullReference("alpine").tag == nil)

    let tagged = DockerClient.splitPullReference("alpine:3.20")
    #expect(tagged.fromImage == "alpine")
    #expect(tagged.tag == "3.20")

    let ghcr = DockerClient.splitPullReference("ghcr.io/x/y:z")
    #expect(ghcr.fromImage == "ghcr.io/x/y")
    #expect(ghcr.tag == "z")

    // Registry with port but no tag: the colon belongs to host:port.
    let portNoTag = DockerClient.splitPullReference("localhost:5000/image")
    #expect(portNoTag.fromImage == "localhost:5000/image")
    #expect(portNoTag.tag == nil)

    // Registry with port and tag.
    let portTagged = DockerClient.splitPullReference("localhost:5000/image:v1")
    #expect(portTagged.fromImage == "localhost:5000/image")
    #expect(portTagged.tag == "v1")

    // Digest reference: kept whole, no tag.
    let digest = DockerClient.splitPullReference("image@sha256:abcdef0123456789")
    #expect(digest.fromImage == "image@sha256:abcdef0123456789")
    #expect(digest.tag == nil)
}

// MARK: - PruneResult tolerant decoding

@Test func pruneResultDecodesImagesShape() throws {
    let json = """
    {"ImagesDeleted":[{"Untagged":"a"},{"Deleted":"b"}],"SpaceReclaimed":12345}
    """
    let result = try JSONDecoder().decode(PruneResult.self, from: Data(json.utf8))
    #expect(result.deletedCount == 2)
    #expect(result.spaceReclaimed == 12345)
}

@Test func pruneResultDecodesContainersShape() throws {
    let json = #"{"ContainersDeleted":["id1","id2","id3"],"SpaceReclaimed":500}"#
    let result = try JSONDecoder().decode(PruneResult.self, from: Data(json.utf8))
    #expect(result.deletedCount == 3)
    #expect(result.spaceReclaimed == 500)
}

@Test func pruneResultDecodesNetworksShapeWithoutSpace() throws {
    let json = #"{"NetworksDeleted":["net1","net2"]}"#
    let result = try JSONDecoder().decode(PruneResult.self, from: Data(json.utf8))
    #expect(result.deletedCount == 2)
    #expect(result.spaceReclaimed == 0)
}

// MARK: - SystemDiskUsage tolerant decoding

@Test func systemDiskUsageDecodesTotals() throws {
    let json = """
    {
      "LayersSize": 1000,
      "Images": [ {"Size": 100}, {"Size": 200} ],
      "Containers": [ {"SizeRw": 50} ],
      "Volumes": [ {"UsageData": {"Size": 300}}, {"UsageData": {"Size": -1}} ]
    }
    """
    let df = try JSONDecoder().decode(SystemDiskUsage.self, from: Data(json.utf8))
    #expect(df.layersSize == 1000)
    #expect(df.imagesCount == 2)
    #expect(df.imagesSize == 300)
    #expect(df.containersCount == 1)
    #expect(df.containersSize == 50)
    #expect(df.volumesCount == 2)
    // -1 (unknown) clamped to 0.
    #expect(df.volumesSize == 300)
}

@Test func systemDiskUsageMapsPerVolumeSizes() throws {
    let json = """
    {
      "Volumes": [
        {"Name": "pgdata", "UsageData": {"Size": 300}},
        {"Name": "cache", "UsageData": {"Size": -1}},
        {"UsageData": {"Size": 500}}
      ]
    }
    """
    let df = try JSONDecoder().decode(SystemDiskUsage.self, from: Data(json.utf8))
    #expect(df.volumeSizes["pgdata"] == 300)
    // -1 (unknown) clamped to 0.
    #expect(df.volumeSizes["cache"] == 0)
    // A row without a name is skipped rather than keyed under "".
    #expect(df.volumeSizes[""] == nil)
    #expect(df.volumeSizes.count == 2)
}

// MARK: - ContainerCreateRequest encoding

@Test func containerCreateRequestEncodesExpectedKeys() throws {
    let config = ContainerCreateRequest(
        image: "nginx:latest",
        cmd: ["nginx", "-g", "daemon off;"],
        env: ["FOO=bar"],
        exposedPorts: ["80/tcp"],
        labels: ["app": "web"],
        tty: false,
        hostConfig: .init(
            binds: ["/host:/container"],
            portBindings: ["80/tcp": [.init(hostIP: "0.0.0.0", hostPort: "8080")]],
            restartPolicy: .init(name: "unless-stopped"),
            memory: 1_000_000,
            nanoCPUs: 500_000_000,
            autoRemove: false,
            privileged: false
        )
    )
    let data = try JSONEncoder().encode(config)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["Image"] as? String == "nginx:latest")
    #expect(object["Cmd"] as? [String] == ["nginx", "-g", "daemon off;"])
    #expect(object["Tty"] as? Bool == false)

    let exposed = try #require(object["ExposedPorts"] as? [String: Any])
    #expect(exposed["80/tcp"] != nil)

    let host = try #require(object["HostConfig"] as? [String: Any])
    #expect(host["Binds"] as? [String] == ["/host:/container"])
    #expect(host["Memory"] as? Int == 1_000_000)
    #expect(host["NanoCpus"] as? Int == 500_000_000)

    let restart = try #require(host["RestartPolicy"] as? [String: Any])
    #expect(restart["Name"] as? String == "unless-stopped")

    let bindings = try #require(host["PortBindings"] as? [String: Any])
    let httpBinding = try #require(bindings["80/tcp"] as? [[String: Any]])
    #expect(httpBinding.first?["HostPort"] as? String == "8080")
    #expect(httpBinding.first?["HostIp"] as? String == "0.0.0.0")
}
