import Foundation
import DockerKit
import AppCore

/// DTOs and helpers for the parity tools (containers/images/volumes/networks/
/// apple/sessions), kept beside the core `DTOs.swift`.

extension GantryTools {
    /// A one-line summary of a prune result.
    func pruneText(_ result: PruneResult, noun: String) -> String {
        let mib = Double(result.spaceReclaimed) / (1024 * 1024)
        let space = result.spaceReclaimed > 0 ? String(format: " (%.1f MiB reclaimed)", mib) : ""
        return "OK: pruned \(result.deletedCount) \(noun)\(space)."
    }
}

struct FileEntryDTO: Encodable {
    var name: String
    var isDirectory: Bool
    var isSymlink: Bool
    var sizeBytes: Int64

    init(_ e: ContainerFileEntry) {
        name = e.name
        isDirectory = e.isDirectory
        isSymlink = e.isSymlink
        sizeBytes = e.size
    }
}

struct MachineDTO: Encodable {
    var name: String
    var status: String
    var cpus: Int
    var memoryBytes: Int64
    var diskBytes: Int64
    var ipAddress: String
    var isDefault: Bool
    var imageReference: String?

    init(_ m: ContainerMachine) {
        name = m.id
        status = m.status
        cpus = m.cpus
        memoryBytes = m.memory
        diskBytes = m.diskSize
        ipAddress = m.ipAddress
        isDefault = m.isDefault
        imageReference = m.imageReference
    }
}

struct TunnelDTO: Encodable {
    var id: String
    var hostID: String
    var containerID: String
    var port: Int
    var mode: String
    var status: String
    var publicURL: String?

    init(_ t: CloudflareTunnel, hostID: String) {
        id = t.id.uuidString
        self.hostID = hostID
        containerID = t.containerID
        port = t.port
        switch t.mode {
        case .quick: mode = "quick"
        case .named(let hostname): mode = "named(\(hostname))"
        }
        switch t.status {
        case .starting: status = "starting"
        case .active: status = "active"
        case .failed(let m): status = "failed: \(m)"
        }
        publicURL = t.publicURL?.absoluteString
    }
}

struct ForwardDTO: Encodable {
    var id: String
    var hostID: String
    var containerID: String
    var localPort: Int
    var remoteHost: String
    var remotePort: Int
    var status: String
    var localURL: String?

    init(_ f: PortForward, hostID: String) {
        id = f.id.uuidString
        self.hostID = hostID
        containerID = f.containerID
        localPort = f.localPort
        remoteHost = f.remoteHost
        remotePort = f.remotePort
        switch f.status {
        case .starting: status = "starting"
        case .active: status = "active"
        case .failed(let m): status = "failed: \(m)"
        }
        localURL = f.localURL?.absoluteString
    }
}
