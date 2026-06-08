import Foundation
@testable import DockerKit

/// A canned-response `DockerTransport` for exercising `DockerClient` /
/// `HostSession` without a live daemon. Routes by `(method, path-prefix)`.
///
/// Paths are matched by suffix-after-version-prefix: the client sends
/// `/v1.47/containers/json`, so a route key of `/containers/json` matches.
final class MockTransport: DockerTransport, @unchecked Sendable {
    struct Route: Sendable {
        var status: Int
        var body: Data
    }

    /// Keyed by "METHOD path-without-version", e.g. "GET /containers/json".
    /// Matched by checking the request path *ends with* the route's path.
    private var routes: [String: Route] = [:]
    private var streamRoutes: [String: (status: Int, lines: [Data])] = [:]
    private(set) var executed: [DockerRequest] = []
    private var hijackHandler: (@Sendable (DockerRequest) -> DockerHijackedConnection)?
    var shutdownCount = 0

    /// Mirrors the transport's build mode. `true` makes `DockerClient` post the
    /// `ImageBuildSpec` JSON to `/build` (apple/container); `false` (default)
    /// takes the daemon tar-upload path.
    var usesCLIBuild: Bool = false

    /// Registers a buffered JSON response for a method/path-suffix.
    func on(_ method: DockerRequest.Method, _ path: String, status: Int = 200, json: String) {
        routes["\(method.rawValue) \(path)"] = Route(status: status, body: Data(json.utf8))
    }

    /// Registers a streaming (JSON-lines) response.
    func onStream(_ path: String, status: Int = 200, lines: [String]) {
        streamRoutes[path] = (status, lines.map { Data(($0 + "\n").utf8) })
    }

    func onHijack(_ handler: @escaping @Sendable (DockerRequest) -> DockerHijackedConnection) {
        hijackHandler = handler
    }

    private func matchBuffered(_ request: DockerRequest) -> Route? {
        for (key, route) in routes {
            let parts = key.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let method = String(parts[0])
            let path = String(parts[1])
            if request.method.rawValue == method, request.path.hasSuffix(path) {
                return route
            }
        }
        return nil
    }

    func execute(_ request: DockerRequest) async throws -> DockerResponse {
        executed.append(request)
        guard let route = matchBuffered(request) else {
            throw DockerError.apiError(status: 599, message: "no mock route for \(request.method.rawValue) \(request.path)")
        }
        return DockerResponse(status: route.status, headers: [:], body: route.body)
    }

    func stream(_ request: DockerRequest) async throws -> DockerByteStream {
        executed.append(request)
        for (path, route) in streamRoutes where request.path.hasSuffix(path) {
            let lines = route.lines
            let bytes = AsyncThrowingStream<Data, Error> { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish()
            }
            return DockerByteStream(status: route.status, headers: [:], bytes: bytes)
        }
        throw DockerError.apiError(status: 599, message: "no mock stream for \(request.path)")
    }

    func hijack(_ request: DockerRequest) async throws -> DockerHijackedConnection {
        executed.append(request)
        if let handler = hijackHandler {
            return handler(request)
        }
        throw DockerError.apiError(status: 599, message: "no mock hijack for \(request.path)")
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

/// A transport that negotiates successfully, then throws `DockerError.cancelled`
/// for every subsequent call. Used to exercise `HostSession.surface`'s
/// cancellation-swallowing branch.
final class CancelTransport: DockerTransport, @unchecked Sendable {
    private let version: String
    init(version: String) { self.version = version }

    func execute(_ request: DockerRequest) async throws -> DockerResponse {
        if request.path.hasSuffix("/version") {
            return DockerResponse(status: 200, headers: [:], body: Data(version.utf8))
        }
        throw DockerError.cancelled
    }
    func stream(_ request: DockerRequest) async throws -> DockerByteStream {
        throw DockerError.cancelled
    }
    func hijack(_ request: DockerRequest) async throws -> DockerHijackedConnection {
        throw DockerError.cancelled
    }
    func shutdown() async {}
}

/// Minimal JSON fixtures for the canned responses.
enum Fixtures {
    static let version = """
    {"Version":"27.0.0","ApiVersion":"1.47","Os":"linux","Arch":"arm64"}
    """

    static func containers(_ entries: [(id: String, state: String)]) -> String {
        let items = entries.map {
            "{\"Id\":\"\($0.id)\",\"State\":\"\($0.state)\",\"Names\":[\"/\($0.id)\"]}"
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    static let images = """
    [{"Id":"sha256:abc","RepoTags":["nginx:latest"],"Size":1000}]
    """

    static let volumes = """
    {"Volumes":[{"Name":"vol1","Driver":"local","Mountpoint":"/x"}],"Warnings":[]}
    """

    static let networks = """
    [{"Id":"net1","Name":"bridge","Driver":"bridge","Scope":"local"}]
    """

    static let info = """
    {"Containers":1,"Images":2,"ServerVersion":"27.0.0"}
    """

    static let containerDetails = """
    {"Id":"c1","State":{"Status":"running","Running":true},"Config":{"Tty":false,"Image":"nginx"}}
    """

    static func pruneContainers(_ ids: [String], reclaimed: Int64) -> String {
        let arr = ids.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"ContainersDeleted\":[\(arr)],\"SpaceReclaimed\":\(reclaimed)}"
    }

    static func pruneImages(count: Int, reclaimed: Int64) -> String {
        let arr = (0..<count).map { _ in "{}" }.joined(separator: ",")
        return "{\"ImagesDeleted\":[\(arr)],\"SpaceReclaimed\":\(reclaimed)}"
    }

    static func statsOnce(total: Int64, system: Int64, online: Int, memUsage: Int64, memLimit: Int64) -> String {
        // Single line: JSON-lines stream parsing requires one object per line.
        "{\"read\":\"2024-01-01T00:00:00.0Z\",\"cpu_stats\":{\"cpu_usage\":{\"total_usage\":\(total)},\"system_cpu_usage\":\(system),\"online_cpus\":\(online)},\"precpu_stats\":{\"cpu_usage\":{\"total_usage\":0},\"system_cpu_usage\":0},\"memory_stats\":{\"usage\":\(memUsage),\"limit\":\(memLimit)}}"
    }

    static func event(type: String, action: String) -> String {
        "{\"Type\":\"\(type)\",\"Action\":\"\(action)\",\"Actor\":{\"ID\":\"x\",\"Attributes\":{}},\"time\":1,\"timeNano\":1}"
    }
}
