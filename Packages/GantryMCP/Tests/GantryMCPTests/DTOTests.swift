import Foundation
import Testing
import DockerKit
import AppCore
@testable import gantry_mcp

@Suite("DTOs")
struct DTOTests {

    /// Round-trips a DTO through `jsonText` and decodes it back as a generic
    /// dictionary for assertions on the wire shape.
    func encodedObject<T: Encodable>(_ dto: T) throws -> [String: Any] {
        let json = try jsonText(dto)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return obj as? [String: Any] ?? [:]
    }

    // MARK: - HostDTO

    @Test func hostDTOForLocalHost() {
        let host = DockerHost(name: "Local", kind: .local)
        let dto = HostDTO(host)
        #expect(dto.kind == "local")
        #expect(dto.name == "Local")
        #expect(dto.id == host.id.uuidString)
        #expect(dto.connectivity.contains("unix socket"))
    }

    @Test func hostDTOForSSHHostWithUser() {
        let endpoint = SSHEndpoint(host: "example.test", port: 2222, username: "deploy")
        let host = DockerHost(name: "Remote", kind: .ssh(endpoint))
        let dto = HostDTO(host)
        #expect(dto.kind == "ssh")
        #expect(dto.connectivity.contains("deploy@example.test:2222"))
        #expect(dto.connectivity.contains("SSH"))
    }

    @Test func hostDTOForSSHHostWithoutUser() {
        let endpoint = SSHEndpoint(host: "example.test", port: 22, username: "")
        let host = DockerHost(name: "Remote", kind: .ssh(endpoint))
        let dto = HostDTO(host)
        // No "@" prefix when username is empty.
        #expect(dto.connectivity.contains("(example.test:22)"))
        #expect(!dto.connectivity.contains("@example.test"))
    }

    @Test func hostDTOEncodesAllFields() throws {
        let dto = HostDTO(DockerHost(name: "Local", kind: .local))
        let obj = try encodedObject(dto)
        #expect(obj["id"] as? String == dto.id)
        #expect(obj["name"] as? String == "Local")
        #expect(obj["kind"] as? String == "local")
        #expect(obj["connectivity"] != nil)
    }

    // MARK: - ContainerDTO

    @Test func containerDTOProjectsSummary() throws {
        let json = """
        {
          "Id": "abcdef0123456789abcdef",
          "Names": ["/web"],
          "Image": "nginx:latest",
          "State": "running",
          "Status": "Up 2 minutes",
          "Ports": [{"PrivatePort": 80, "PublicPort": 8080, "Type": "tcp", "IP": "0.0.0.0"}],
          "Labels": {"com.docker.compose.project": "myproj"}
        }
        """
        let summary = try decodeJSON(ContainerSummary.self, json)
        let dto = ContainerDTO(summary)
        #expect(dto.id == "abcdef012345")
        #expect(dto.name == "web")
        #expect(dto.image == "nginx:latest")
        #expect(dto.state == "running")
        #expect(dto.status == "Up 2 minutes")
        #expect(dto.ports.count == 1)
        #expect(dto.ports[0].contains("8080"))
        #expect(dto.composeProject == "myproj")
    }

    @Test func containerDTONoComposeProject() throws {
        let json = """
        {"Id": "deadbeefcafebabe", "Names": ["/x"], "Image": "busybox", "State": "exited", "Status": "Exited (0)"}
        """
        let summary = try decodeJSON(ContainerSummary.self, json)
        let dto = ContainerDTO(summary)
        #expect(dto.composeProject == nil)
        #expect(dto.ports.isEmpty)
    }

    @Test func containerListDTOEncodesError() throws {
        let dto = ContainerListDTO(hostID: "h", hostName: "Local", containers: [], error: "boom")
        let obj = try encodedObject(dto)
        #expect(obj["error"] as? String == "boom")
        #expect((obj["containers"] as? [Any])?.isEmpty == true)
    }

    // MARK: - ImageDTO

    @Test func imageDTOProjectsSummary() throws {
        let json = """
        {"Id": "sha256:1234567890abcdef1234", "RepoTags": ["app:1.0"], "Size": 12345, "Created": 1700000000}
        """
        let summary = try decodeJSON(ImageSummary.self, json)
        let dto = ImageDTO(summary)
        #expect(dto.id == "1234567890ab")
        #expect(dto.tags == ["app:1.0"])
        #expect(dto.sizeBytes == 12345)
        #expect(dto.created == 1700000000)
    }

    // MARK: - VolumeDTO

    @Test func volumeDTOProjectsModel() throws {
        let json = """
        {"Name": "data", "Driver": "local", "Mountpoint": "/var/lib/docker/volumes/data/_data", "Scope": "local"}
        """
        let v = try decodeJSON(Volume.self, json)
        let dto = VolumeDTO(v)
        #expect(dto.name == "data")
        #expect(dto.driver == "local")
        #expect(dto.mountpoint.contains("data"))
        #expect(dto.scope == "local")
    }

    // MARK: - NetworkDTO

    @Test func networkDTOProjectsModel() throws {
        let json = """
        {"Id": "net0123456789abcdef", "Name": "bridge", "Driver": "bridge", "Scope": "local"}
        """
        let n = try decodeJSON(NetworkResource.self, json)
        let dto = NetworkDTO(n)
        #expect(dto.id == "net012345678")
        #expect(dto.name == "bridge")
        #expect(dto.driver == "bridge")
        #expect(dto.scope == "local")
    }

    // MARK: - StatsDTO

    @Test func statsDTORoundsAndProjects() throws {
        let json = """
        {
          "read": "2024-01-01T00:00:00.000000000Z",
          "cpu_stats": {"cpu_usage": {"total_usage": 200}, "system_cpu_usage": 1000, "online_cpus": 2},
          "precpu_stats": {"cpu_usage": {"total_usage": 100}, "system_cpu_usage": 500},
          "memory_stats": {"usage": 1048576, "limit": 2097152, "stats": {"inactive_file": 0}},
          "networks": {"eth0": {"rx_bytes": 500, "tx_bytes": 700}},
          "pids_stats": {"current": 3}
        }
        """
        let sample = try decodeJSON(ContainerStatsSample.self, json)
        let dto = StatsDTO(containerID: "c1", sample)
        #expect(dto.containerID == "c1")
        #expect(dto.memoryUsedBytes == 1048576)
        #expect(dto.memoryLimitBytes == 2097152)
        #expect(dto.networkRxBytes == 500)
        #expect(dto.networkTxBytes == 700)
        #expect(dto.pids == 3)
        // cpuPercent and memoryPercent are rounded to 2 decimals.
        #expect((dto.cpuPercent * 100).rounded() == dto.cpuPercent * 100)
        #expect((dto.memoryPercent * 100).rounded() == dto.memoryPercent * 100)
    }

    // MARK: - ExecResultDTO

    @Test func execResultDTOEncodes() throws {
        let dto = ExecResultDTO(containerID: "c1", command: "echo hi", exitCode: 0, stdout: "hi", stderr: "")
        let obj = try encodedObject(dto)
        #expect(obj["containerID"] as? String == "c1")
        #expect(obj["command"] as? String == "echo hi")
        #expect(obj["exitCode"] as? Int == 0)
        #expect(obj["stdout"] as? String == "hi")
    }

    @Test func execResultDTONilExitCode() throws {
        let dto = ExecResultDTO(containerID: "c1", command: "x", exitCode: nil, stdout: "", stderr: "err")
        let obj = try encodedObject(dto)
        // nil exitCode is omitted by JSONEncoder default.
        #expect(obj["exitCode"] == nil)
        #expect(obj["stderr"] as? String == "err")
    }

    // MARK: - DiskUsageDTO

    @Test func diskUsageDTOProjectsCategories() throws {
        let df = SystemDiskUsage(
            images: .init(count: 3, totalSizeBytes: 1000, reclaimableBytes: 400),
            containers: .init(count: 2, totalSizeBytes: 200, reclaimableBytes: 50),
            volumes: .init(count: 1, totalSizeBytes: 5000, reclaimableBytes: 5000),
            buildCacheBytes: 777
        )
        let dto = DiskUsageDTO(hostID: "h", hostName: "Local", df)
        #expect(dto.images.count == 3)
        #expect(dto.images.totalSizeBytes == 1000)
        #expect(dto.images.reclaimableBytes == 400)
        #expect(dto.containers.count == 2)
        #expect(dto.volumes.totalSizeBytes == 5000)
        #expect(dto.buildCacheBytes == 777)

        let obj = try encodedObject(dto)
        #expect(obj["hostName"] as? String == "Local")
        #expect((obj["images"] as? [String: Any])?["count"] as? Int == 3)
    }
}
