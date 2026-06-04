import Foundation

extension DockerClient {
    // MARK: - Volumes

    /// `POST /volumes/create`.
    public func createVolume(
        name: String,
        driver: String = "local",
        labels: [String: String] = [:]
    ) async throws -> Volume {
        struct CreateRequest: Encodable {
            var name: String
            var driver: String
            var labels: [String: String]
            enum CodingKeys: String, CodingKey {
                case name = "Name"
                case driver = "Driver"
                case labels = "Labels"
            }
        }
        let body = try JSONEncoder().encode(CreateRequest(name: name, driver: driver, labels: labels))
        let response = try await requestData(
            method: .post,
            path: "/volumes/create",
            headers: ["Content-Type": "application/json"],
            body: body,
            expecting: [201]
        )
        return try decode(Volume.self, from: response.body, path: "/volumes/create")
    }

    /// `POST /volumes/prune`.
    public func pruneVolumes() async throws -> PruneResult {
        let response = try await requestData(method: .post, path: "/volumes/prune", expecting: [200])
        return try decode(PruneResult.self, from: response.body, path: "/volumes/prune")
    }

    // MARK: - Networks

    /// `POST /networks/create` — returns the new network's id.
    public func createNetwork(
        name: String,
        driver: String = "bridge",
        labels: [String: String] = [:]
    ) async throws -> String {
        struct CreateRequest: Encodable {
            var name: String
            var driver: String
            var labels: [String: String]
            enum CodingKeys: String, CodingKey {
                case name = "Name"
                case driver = "Driver"
                case labels = "Labels"
            }
        }
        let body = try JSONEncoder().encode(CreateRequest(name: name, driver: driver, labels: labels))
        let response = try await requestData(
            method: .post,
            path: "/networks/create",
            headers: ["Content-Type": "application/json"],
            body: body,
            expecting: [201]
        )
        return try decode(IDResponse.self, from: response.body, path: "/networks/create").id
    }

    /// `POST /networks/prune`. Network prune reclaims no space; reports 0 bytes.
    public func pruneNetworks() async throws -> PruneResult {
        let response = try await requestData(method: .post, path: "/networks/prune", expecting: [200])
        return try decode(PruneResult.self, from: response.body, path: "/networks/prune")
    }

    /// `POST /networks/{id}/connect` — attaches a container to a network.
    public func connectContainer(networkID: String, containerID: String) async throws {
        struct ConnectRequest: Encodable {
            var container: String
            enum CodingKeys: String, CodingKey { case container = "Container" }
        }
        let body = try JSONEncoder().encode(ConnectRequest(container: containerID))
        _ = try await requestData(
            method: .post,
            path: "/networks/\(networkID)/connect",
            headers: ["Content-Type": "application/json"],
            body: body,
            expecting: [200]
        )
    }

    /// `POST /networks/{id}/disconnect` — detaches a container from a network.
    public func disconnectContainer(networkID: String, containerID: String, force: Bool = false) async throws {
        struct DisconnectRequest: Encodable {
            var container: String
            var force: Bool
            enum CodingKeys: String, CodingKey {
                case container = "Container"
                case force = "Force"
            }
        }
        let body = try JSONEncoder().encode(DisconnectRequest(container: containerID, force: force))
        _ = try await requestData(
            method: .post,
            path: "/networks/\(networkID)/disconnect",
            headers: ["Content-Type": "application/json"],
            body: body,
            expecting: [200]
        )
    }
}
