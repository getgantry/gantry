import Foundation
import DockerKit
import AppCore

/// Flat, agent-friendly projections of DockerKit models. These are what the
/// tools serialize to JSON, keeping the wire shape stable and readable.

struct HostDTO: Encodable {
    var id: String
    var name: String
    var kind: String
    var connectivity: String

    init(_ host: DockerHost) {
        id = host.id.uuidString
        name = host.name
        switch host.kind {
        case .local:
            kind = "local"
            connectivity = "Local Docker daemon via unix socket."
        case .ssh(let endpoint):
            kind = "ssh"
            let user = endpoint.username.isEmpty ? "" : "\(endpoint.username)@"
            connectivity = "Remote Docker over SSH (\(user)\(endpoint.host):\(endpoint.port)). Headless access requires the host key to be already trusted."
        }
    }
}

struct ContainerDTO: Encodable {
    var id: String
    var name: String
    var image: String
    var state: String
    var status: String
    var ports: [String]
    var composeProject: String?

    init(_ c: ContainerSummary) {
        id = c.shortID
        name = c.displayName
        image = c.image
        state = c.state.rawValue
        status = c.status
        ports = c.ports.map(\.display)
        composeProject = c.composeProject
    }
}

struct ContainerListDTO: Encodable {
    var hostID: String
    var hostName: String
    var containers: [ContainerDTO]
    var error: String?
}

struct ImageDTO: Encodable {
    var id: String
    var tags: [String]
    var sizeBytes: Int64
    var created: Int64

    init(_ i: ImageSummary) {
        id = i.shortID
        tags = i.repoTags
        sizeBytes = i.size
        created = i.created
    }
}

struct ImageListDTO: Encodable {
    var hostID: String
    var hostName: String
    var images: [ImageDTO]
    var error: String?
}

struct VolumeDTO: Encodable {
    var name: String
    var driver: String
    var mountpoint: String
    var scope: String

    init(_ v: Volume) {
        name = v.name
        driver = v.driver
        mountpoint = v.mountpoint
        scope = v.scope
    }
}

struct VolumeListDTO: Encodable {
    var hostID: String
    var hostName: String
    var volumes: [VolumeDTO]
    var error: String?
}

struct NetworkDTO: Encodable {
    var id: String
    var name: String
    var driver: String
    var scope: String

    init(_ n: NetworkResource) {
        id = n.shortID
        name = n.name
        driver = n.driver
        scope = n.scope
    }
}

struct NetworkListDTO: Encodable {
    var hostID: String
    var hostName: String
    var networks: [NetworkDTO]
    var error: String?
}

struct StatsDTO: Encodable {
    var containerID: String
    var cpuPercent: Double
    var memoryUsedBytes: Int64
    var memoryLimitBytes: Int64
    var memoryPercent: Double
    var networkRxBytes: Int64
    var networkTxBytes: Int64
    var pids: Int

    init(containerID: String, _ s: ContainerStatsSample) {
        self.containerID = containerID
        cpuPercent = (s.cpuPercent * 100).rounded() / 100
        memoryUsedBytes = s.memoryUsageBytes
        memoryLimitBytes = s.memoryLimitBytes
        memoryPercent = (s.memoryPercent * 100).rounded() / 100
        networkRxBytes = s.networkRxBytes
        networkTxBytes = s.networkTxBytes
        pids = s.pids
    }
}

struct ExecResultDTO: Encodable {
    var containerID: String
    var command: String
    var exitCode: Int?
    var stdout: String
    var stderr: String
}

struct DiskUsageDTO: Encodable {
    struct Category: Encodable {
        var count: Int
        var totalSizeBytes: Int64
        var reclaimableBytes: Int64
    }
    var hostID: String
    var hostName: String
    var images: Category
    var containers: Category
    var volumes: Category
    var buildCacheBytes: Int64

    init(hostID: String, hostName: String, _ df: SystemDiskUsage) {
        self.hostID = hostID
        self.hostName = hostName
        images = .init(count: df.images.count, totalSizeBytes: df.images.totalSizeBytes, reclaimableBytes: df.images.reclaimableBytes)
        containers = .init(count: df.containers.count, totalSizeBytes: df.containers.totalSizeBytes, reclaimableBytes: df.containers.reclaimableBytes)
        volumes = .init(count: df.volumes.count, totalSizeBytes: df.volumes.totalSizeBytes, reclaimableBytes: df.volumes.reclaimableBytes)
        buildCacheBytes = df.buildCacheBytes
    }
}
